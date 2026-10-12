# Operations

See [Disaster recovery](DISASTER-RECOVERY.md) before storing production data. This project requires Docker Compose V2, `restic` (0.17+ recommended), Python 3, `tar`, and a Linux host. It uses `flock` when available and an atomic lock-directory fallback otherwise. Docker access to the configured image registries is needed for both image pulls and logical-dump validation. The repo is `gitea-prod` on every host; the machine name is snapshot metadata only.

## Configure and first boot

1. Install Docker Engine/Compose, restic, and Python 3. Configure the existing Caddy instance to join the external Docker network named by `PROXY_NETWORK`, then proxy to `gitea:3000` using `config/Caddyfile.example`. This network must exist before Compose starts.
2. Copy `.env.example` to `.env`; replace all placeholders and set the real B2 S3 endpoint and bucket. Choose a unique restic password and B2 Application Key; keep the recovery set outside the VPS (for example, encrypted offline storage). `chmod 600 .env`. Set `PROXY_NETWORK` to Caddy's existing Docker network. Add `ADMIN_EMAIL` and a strong temporary `ADMIN_PASSWORD`; protect `.env` as a secret.
3. Initialize the dedicated encrypted repository once, before first backup: `./manage.sh backup init`. Keep the password and B2 recovery key off-host. Do not run `restic init` for restore or to resolve repository errors.
4. Ensure `/srv/gitea` is on persistent SSD, has enough free space for a full staged copy plus archive, and is owned/writable by Gitea UID 1000.
5. Explicitly initialize: `./manage.sh init --fresh --confirm-fresh`. Fresh init refuses non-empty data paths. `docker compose up -d` is not a bootstrap command; use `manage.sh`.
6. Install a separate, isolated Gitea Actions runner (for example in a dedicated VM). Never mount the production Docker socket or provide production credentials to the runner. The runner is optional for Gitea startup.
7. In Gitea, enable 2FA for the administrator and configure branch protection on `main`, requiring the desired CI status. CI is enabled but protections are a per-repository administrative setting.

Gitea HTTP is reachable by Caddy through its external Docker network and is also bound to a configurable loopback host port for maintenance; SSH is published on TCP 2222 and must be permitted by the host firewall if SSH cloning is desired. Database port 5432 is private to the Compose network. Packages are disabled. Actions artifacts are retained for 30 days; caches/artifacts are not part of backup.

## Backups

`./manage.sh backup now` serializes operations with a host lock, stops Gitea while taking `pg_dump -Fc` and a permission-preserving tar of `/data`, restarts Gitea on success or failure, then submits one restic snapshot tagged `gitea-prod`. Disk capacity must accommodate staging; the script intentionally does not attempt an unbounded pre-copy. It removes staging on exit. A successful restic command means the upload completed; retain external monitoring around its exit code. Do not report success until command completes.

Set a systemd timer/cron on the host to invoke `manage.sh backup now` every six hours (example systemd units are in `systemd/`). Run the initial backup manually. Run `./manage.sh backup list`; weekly `backup verify` checks the repository and reads a 5% data subset. Schedule a monthly restore drill on a separate clean host. Run `./manage.sh backup prune` weekly; it applies the configured daily/weekly/monthly retention under the same operation lock. The included `systemd/gitea-prune.timer` schedules it weekly.

Run `tests/integration.sh` to perform a local Compose fresh-init, Git clone/push, restic backup, restore to clean paths, and post-restore Git smoke test.

Stack-back v1.5.4 was inspected, but its auto-detection/backups do not guarantee the required coordinated Gitea stop, PostgreSQL logical dump, and single restore unit; this deployment uses official restic commands and a small script instead of claiming unsafe plugin coordination.

## Update and monitoring

Pin image versions in `.env`; do not use `latest`. Back up immediately before changing `GITEA_VERSION` or PostgreSQL major version. Gitea upgrades can migrate the database and may not be reversible; rollback by restoring the prior complete snapshot into clean paths and reverting image versions. Upgrade PostgreSQL majors only using its documented migration procedure. Keep host security updates current.

`./manage.sh status` shows Compose state and latest snapshot. Backup/verification errors return non-zero. Alert on non-zero exit with host monitoring/Uptime Kuma; never send success heartbeat before command success.
