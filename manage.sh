#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] || { echo "Missing .env; copy .env.example and configure secrets." >&2; exit 2; }
chmod 600 .env
while IFS= read -r -d '' entry; do export "$entry"; done < <(python3 scripts/load-env.py .env)
: "${DATA_DIR:?}" "${PGDATA_DIR:?}" "${STAGING_DIR:?}" "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}"
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
COMPOSE=(docker compose --env-file .env -f compose.yaml)
LOCK="${STAGING_DIR}/.operation.lock"
mkdir -p "$(dirname "$LOCK")"
release_lock(){ rmdir "$LOCK.d" 2>/dev/null || true; }
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then echo "Another backup/restore/init operation holds $LOCK" >&2; exit 1; fi
  release_lock(){ flock -u 9; exec 9>&-; }
else
  mkdir "$LOCK.d" 2>/dev/null || { echo "Another operation holds $LOCK.d" >&2; exit 1; }
  trap release_lock EXIT
fi
usage(){ echo "Usage: $0 init --fresh | init --restore | restore --snapshot ID | restore --latest | backup now|list|verify|prune | status"; }
empty_dir(){ [[ ! -d "$1" ]] || [[ -z "$(ls -A "$1")" ]]; }
repo_check(){ restic snapshots >/dev/null; }
case "${1:-}" in
  init)
    case "${2:-}" in
      --fresh)
        [[ "${3:-}" == "--confirm-fresh" ]] || { echo "Explicit confirmation required: init --fresh --confirm-fresh" >&2; exit 2; }
        mkdir -p "$DATA_DIR" "$PGDATA_DIR"
        empty_dir "$DATA_DIR" && empty_dir "$PGDATA_DIR" || { echo "Refusing fresh init: data paths are not empty." >&2; exit 1; }
        ((${#POSTGRES_PASSWORD} >= 24 && ${#GITEA_SECRET_KEY} >= 32 && ${#GITEA_INTERNAL_TOKEN} >= 32)) || { echo "Use long random DB and Gitea secrets before init." >&2; exit 2; }
        repo_check
        EXISTING="$(restic snapshots --json | python3 -c 'import json,sys; print(sum("gitea-prod" in (s.get("tags") or []) for s in json.load(sys.stdin)))')"
        [[ "$EXISTING" == 0 ]] || { echo "Refusing fresh init: gitea-prod snapshots already exist; choose restore." >&2; exit 1; }
        BOOTSTRAP_ALLOW_FRESH=true "${COMPOSE[@]}" up -d db
        db_ready=false
        for _ in {1..60}; do
          if "${COMPOSE[@]}" exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then db_ready=true; break; fi
          sleep 2
        done
        $db_ready || { echo "PostgreSQL did not become ready within 120 seconds." >&2; exit 1; }
        BOOTSTRAP_ALLOW_FRESH=true "${COMPOSE[@]}" up -d --force-recreate bootstrap gitea
        ready=false
        for _ in {1..60}; do
          if "${COMPOSE[@]}" exec -T -u git gitea gitea admin user list >/dev/null 2>&1; then ready=true; break; fi
          if [[ "$(docker inspect -f '{{.State.Running}}' "$("${COMPOSE[@]}" ps -q gitea)")" != true ]]; then
            echo "Gitea container exited before becoming ready." >&2; exit 1
          fi
          sleep 2
        done
        $ready || { echo "Gitea did not become ready within 120 seconds." >&2; exit 1; }
        "${COMPOSE[@]}" exec -T -u git gitea gitea admin user create --username admin --email "${ADMIN_EMAIL:?set ADMIN_EMAIL in .env}" --admin --password "${ADMIN_PASSWORD:?set ADMIN_PASSWORD in .env}" --must-change-password=false
        touch "$DATA_DIR/.deployment-ready"
        ;;
      --restore)
        repo_check
        restic snapshots --tag gitea-prod
        read -r -p "Snapshot ID to restore (exact ID or short ID): " SNAP
        [[ -n "$SNAP" ]] || { echo "No snapshot selected." >&2; exit 2; }
        read -r -p "Type RESTORE to confirm restoring $SNAP into empty paths: " ANSWER
        [[ "$ANSWER" == RESTORE ]] || { echo "Restore cancelled."; exit 1; }
        release_lock
        RESTORE_CONFIRM="gitea-prod:$SNAP" exec "$0" restore --snapshot "$SNAP"
        ;;
      *) usage; exit 2 ;;
    esac ;;
  restore)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    case "$2" in
      --snapshot) SNAP="${3:?snapshot ID required}" ;;
      --latest) SNAP=latest ;;
      *) usage; exit 2 ;;
    esac
    [[ -n "${3:-}" || "$SNAP" == latest ]] || { usage; exit 2; }
    mkdir -p "$STAGING_DIR"
    [[ ! -e "$STAGING_DIR/restore" ]] || { echo "Restore staging already exists; inspect/clear it explicitly before retry." >&2; exit 1; }
    mkdir -p "$DATA_DIR" "$PGDATA_DIR"
    if "${COMPOSE[@]}" ps --status running --services | grep -qx gitea; then echo "Stop Gitea before restore." >&2; exit 1; fi
    empty_dir "$DATA_DIR" && empty_dir "$PGDATA_DIR" || { echo "Restore only supports empty target directories; preserve existing data and use a clean host." >&2; exit 1; }
    repo_check
    mkdir -p "$STAGING_DIR"
    restic snapshots --json > "$STAGING_DIR/snapshots.json"
    SELECTION="$(python3 - "$STAGING_DIR/snapshots.json" "$SNAP" <<'PY'
import json, sys
snapshots = json.load(open(sys.argv[1]))
valid = [s for s in snapshots if "gitea-prod" in (s.get("tags") or [])]
for s in valid:
    print(s["short_id"], s.get("time"), s.get("hostname"), s.get("tags"))
wanted = sys.argv[2]
selected = max(valid, key=lambda s: s["time"]) if wanted == "latest" and valid else next((s for s in valid if wanted in (s["id"], s["short_id"])), None)
print("SELECTED=" + (selected["id"] if selected else ""))
PY
)"
    printf '%s\n' "$SELECTION" | sed -n 's/^SELECTED=//p' > "$STAGING_DIR/selected-snapshot"
    SELECTED="$(cat "$STAGING_DIR/selected-snapshot")"
    [[ -n "$SELECTED" ]] || { echo "Requested snapshot not found in gitea-prod snapshots." >&2; exit 1; }
    [[ "${RESTORE_CONFIRM:-}" == "gitea-prod:${SNAP}" ]] || { echo "Review listed snapshots; confirm with RESTORE_CONFIRM=gitea-prod:${SNAP} $0 restore ${2} ${3:-}" >&2; exit 2; }
    mkdir -p "$STAGING_DIR/restore"
    cleanup_restore_stage(){ rm -rf "$STAGING_DIR/restore"; }
    trap cleanup_restore_stage EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    restic restore "$SELECTED" --target "$STAGING_DIR/restore"
    SRC="$STAGING_DIR/restore/payload/srv/gitea-prod"
    [[ -s "$SRC/gitea-data.tar" && -s "$SRC/database.dump" && -s "$SRC/manifest.txt" ]] || { echo "Snapshot lacks required payload; refusing restore." >&2; exit 1; }
    tar -tf "$SRC/gitea-data.tar" >/dev/null
    grep -Fx "gitea_version=$GITEA_VERSION" "$SRC/manifest.txt" >/dev/null || { echo "Snapshot Gitea version differs from configured image; use the matching release." >&2; exit 1; }
    grep -Fx "postgres_version=$POSTGRES_VERSION" "$SRC/manifest.txt" >/dev/null || { echo "Snapshot PostgreSQL version differs from configured image; use the matching release." >&2; exit 1; }
    docker run --rm -i "postgres:${POSTGRES_VERSION}@${POSTGRES_IMAGE_DIGEST}" pg_restore --list < "$SRC/database.dump" >/dev/null
    # Targets are verified empty above; a failed import rolls back only these new paths.
    rollback_restore(){
      "${COMPOSE[@]}" stop gitea db >/dev/null 2>&1 || true
      rm -rf "$DATA_DIR" "$PGDATA_DIR" "$STAGING_DIR/restore"
    }
    trap rollback_restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tar -xpf "$SRC/gitea-data.tar" -C "$DATA_DIR"
    rm -f "$DATA_DIR/.deployment-ready"
    BOOTSTRAP_ALLOW_RESTORE=true "${COMPOSE[@]}" up -d db
    db_ready=false
        for _ in {1..60}; do
          if "${COMPOSE[@]}" exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then db_ready=true; break; fi
          sleep 2
        done
        $db_ready || { echo "PostgreSQL did not become ready within 120 seconds." >&2; exit 1; }
    "${COMPOSE[@]}" exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --role "$POSTGRES_USER" --clean --if-exists < "$SRC/database.dump"
    touch "$DATA_DIR/.deployment-ready"
    "${COMPOSE[@]}" up -d --force-recreate bootstrap gitea
    rm -rf "$STAGING_DIR/restore"
    trap - EXIT INT TERM
    echo "Restore payload installed. Verify UI, users, issues, repositories, clone/fetch/push before serving traffic."
    ;;
  backup)
    case "${2:-}" in
      init) restic init ;;
      now)
        mkdir -p "$STAGING_DIR"; [[ ! -e "$STAGING_DIR/payload" ]] || { echo "Backup staging path already exists; inspect it, do not delete it implicitly." >&2; exit 1; }; mkdir -p "$STAGING_DIR/payload/srv/gitea-prod"
        was_running=false; "${COMPOSE[@]}" ps --status running --services | grep -qx gitea && was_running=true || true
        restore_service(){ if $was_running; then "${COMPOSE[@]}" start gitea >/dev/null || true; fi; rm -rf "$STAGING_DIR/payload"; release_lock; }
        trap restore_service EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if $was_running; then "${COMPOSE[@]}" stop -t 60 gitea; else echo "Gitea must be running for a complete backup; refusing partial backup." >&2; exit 1; fi
        "${COMPOSE[@]}" exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$STAGING_DIR/payload/srv/gitea-prod/database.dump"
        tar -cpf "$STAGING_DIR/payload/srv/gitea-prod/gitea-data.tar" -C "$DATA_DIR" .
        { printf 'service=gitea-prod\n'; printf 'gitea_version=%s\npostgres_version=%s\n' "$GITEA_VERSION" "$POSTGRES_VERSION"; printf 'created_utc=%s\n' "$(date -u +%FT%TZ)"; printf 'host=%s\n' "$(hostname)"; printf 'data_dir=%s\n' "$DATA_DIR"; } > "$STAGING_DIR/payload/srv/gitea-prod/manifest.txt"
        "${COMPOSE[@]}" start gitea >/dev/null
        (cd "$STAGING_DIR" && restic backup payload --tag gitea-prod --tag "gitea-${GITEA_VERSION}" --host "$(hostname)")
        restic snapshots --latest 1 --tag gitea-prod
        ;;
      list) repo_check; restic snapshots --tag gitea-prod ;;
      verify) repo_check; restic check --read-data-subset=5%; restic snapshots --tag gitea-prod --latest 1 ;;
      prune)
        repo_check
        restic forget --tag gitea-prod --keep-daily "${KEEP_DAILY:?}" --keep-weekly "${KEEP_WEEKLY:?}" --keep-monthly "${KEEP_MONTHLY:?}" --prune
        ;;
      *) usage; exit 2 ;;
    esac ;;
  status)
    "${COMPOSE[@]}" ps
    restic snapshots --tag gitea-prod --latest 1
    ;;
  *) usage; exit 2 ;;
esac
