# Disaster recovery

## Recovery material (must exist off-host)

- This deployment repository and exact Gitea/PostgreSQL image versions used by the selected snapshot.
- `.env` secrets: B2 endpoint/repository, B2 key ID/application key, restic password, database password, Gitea `SECRET_KEY` and `INTERNAL_TOKEN`. Keep the same app secrets: changing them can invalidate encrypted data/tokens.
- Administrator recovery credentials, domain/DNS control, Caddy configuration and firewall access.

No backup can restore credentials that were never saved outside the lost host.

## Restore on a clean Linux host

1. Install Docker/Compose, restic, and `flock`; clone this repo. Configure `.env` with the same secrets and repository, and set DATA_DIR/PGDATA_DIR/STAGING_DIR to new empty paths. Do not use `init --fresh`.
2. Test access with `restic snapshots --tag gitea-prod`. Wrong credentials, unreachable B2, or no snapshots are errors; do not initialize a new production instance.
3. Review available snapshot IDs, timestamps, tags and host origin using `./manage.sh backup list`. Select the exact snapshot, not an implicit latest, when recovery point matters.
4. Use the exact image versions recorded in the snapshot manifest (default `.env.example` values only match snapshots created with these pinned images). Restore requires empty data and database directories and an explicit confirmation. Example: `RESTORE_CONFIRM=gitea-prod:SNAPSHOT_ID ./manage.sh restore --snapshot SNAPSHOT_ID`. For explicitly latest: `RESTORE_CONFIRM=gitea-prod:latest ./manage.sh restore --latest`. Interactive selection is available with `./manage.sh init --restore`.
5. The command downloads the selected snapshot to staging, validates required files and the tar archive, extracts Gitea data only into empty storage, initializes PostgreSQL and imports the logical dump, then starts Gitea. If interrupted, do not start Gitea; preserve partial data and repeat on fresh empty target paths. Never restore over live data.
6. Verify version compatibility, admin login, users, repositories, issues/PRs, attachments/LFS, secret-dependent integrations, then clone/fetch/push using HTTPS and SSH. Reconfigure Caddy/DNS/firewall and isolated runner. Record measured RPO/RTO.
7. After validation, run `./manage.sh backup now` to establish a local-host-origin snapshot. Repeated `docker compose up -d` does not rerun restore.

Do not use a raw PostgreSQL data-directory copy; this backup contains a custom-format logical dump. Verify a real recovery monthly on a separate disposable host.
