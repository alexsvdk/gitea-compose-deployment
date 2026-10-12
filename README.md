# Gitea deployment (`git.svdk.dev`)

Single-instance Gitea + PostgreSQL Compose deployment behind existing Caddy, with encrypted restic snapshots in Backblaze B2 and a deliberate restore workflow. The persistent identity and restic tags are `gitea-prod`, independent of host.

**Production image pins use Gitea 28.1.0 with a verified digest. Compose startup is fail-closed behind a bootstrap gate; use the explicit `manage.sh` commands.**

Read [Operations](docs/OPERATIONS.md) and [Disaster recovery](docs/DISASTER-RECOVERY.md) first. Configure secrets from `.env.example`; never commit `.env`. Run only `./manage.sh init --fresh --confirm-fresh` for a confirmed new empty install. For recovery, use `./manage.sh backup list` and `./manage.sh restore --snapshot ID`.

Useful commands: `./manage.sh backup now|list|verify|prune`, `./manage.sh status`. Caddy must join the external Docker network configured by `PROXY_NETWORK` and proxy to `gitea:3000`. Gitea SSH is available on TCP 2222. CI runners are independent and must not have production Docker socket access.

Run the full local lifecycle test with `tests/integration.sh` (requires Docker, restic, curl, git, and Linux-style shell utilities). This project uses a small, auditable restic wrapper rather than Stack-back because its generic discovery does not establish an atomic stopped-Gitea + logical-PostgreSQL snapshot. This is an MVP deployment: validate backups and perform the documented clean-host restore drill before entrusting it with data.
