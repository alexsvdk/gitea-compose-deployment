# Operations

See [Disaster recovery](DISASTER-RECOVERY.md) before storing production data. This project requires Docker Compose V2, `restic` (0.17+ recommended), `flock`, `tar`, and a Linux host. Docker access to the configured image registries is needed for both image pulls and logical-dump validation. The repo is `gitea-prod` on every host; the machine name is snapshot metadata only.

## Configure and first boot

1. Install Docker Engine/Compose, restic, and `flock`. Configure the existing Caddy instance to proxy to `127.0.0.1:3000` using `config/Caddyfile.example`.
2. Copy `.env.example` to `.env`; replace all placeholders and set the real B2 S3 endpoint and bucket. Choose a unique restic password and B2 Application Key; keep the recovery set outside the VPS (for example, encrypted offline storage). `chmod 600 .env`. Add `ADMIN_EMAIL` and a strong temporary `ADMIN_PASSWORD`; protect `.env` as a secret.
3. Initialize the dedicated encrypted repository once, before first backup: `set -a; source .env; set +a; restic init`. Keep the password and B2 recovery key off-host. Do not run `restic init` for restore or to resolve repository errors.
4. Ensure `/srv/gitea` is on persistent SSD, has enough free space for a full staged copy plus archive, and is owned/writable by Gitea UID 1000.
5. Explicitly initialize: `./manage.sh init --fresh --confirm-fresh`. Fresh init refuses non-empty data paths. `docker compose up -d` is not a bootstrap command; use `manage.sh`.
6. Install a separate, isolated Gitea Actions runner (for example in a dedicated VM). Never mount the production Docker socket or provide production credentials to the runner. The runner is optional for Gitea startup.
7. In Gitea, enable 2FA for the administrator and configure branch protection on `main`, requiring the desired CI status. CI is enabled but protections are a per-repository administrative setting.

Gitea binds HTTP only to loopback; SSH is published on TCP 2222 and must be permitted by the host firewall if SSH cloning is desired. Database port 5432 is private to the Compose network. Packages are disabled. Actions artifacts are retained for 30 days; caches/artifacts are not part of backup.

## Backups

`./manage.sh backup now` serializes operations with a host lock, stops Gitea while taking `pg_dump -Fc` and a permission-preserving tar of `/data`, restarts Gitea on success or failure, then submits one restic snapshot tagged `gitea-prod`. Disk capacity must accommodate staging; the script intentionally does not attempt an unbounded pre-copy. It removes staging on exit. A successful restic command means the upload completed; retain external monitoring around its exit code. Do not report success until command completes.

Set a systemd timer/cron on the host to invoke `manage.sh backup now` every six hours (example systemd units are in `systemd/`). Run the initial backup manually. Run `./manage.sh backup list`; weekly `backup verify` checks the repository and reads a 5% data subset. Schedule a monthly restore drill on a separate clean host. Retention/prune is intentionally separate: after confirming recent snapshots and recovery access, run `restic forget --tag gitea-prod --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune` while no backup or restore is running (the manage lock does not cover an external restic command).

Stack-back v1.5.4 was inspected, but its auto-detection/backups do not guarantee the required coordinated Gitea stop, PostgreSQL logical dump, and single restore unit; this deployment uses official restic commands and a small script instead of claiming unsafe plugin coordination.

## Update and monitoring

Pin image versions in `.env`; do not use `latest`. Back up immediately before changing `GITEA_VERSION` or PostgreSQL major version. Gitea upgrades can migrate the database and may not be reversible; rollback by restoring the prior complete snapshot into clean paths and reverting image versions. Upgrade PostgreSQL majors only using its documented migration procedure. Keep host security updates current.

`./manage.sh status` shows Compose state and latest snapshot. Backup/verification errors return non-zero. Alert on non-zero exit with host monitoring/Uptime Kuma; never send success heartbeat before command success.
