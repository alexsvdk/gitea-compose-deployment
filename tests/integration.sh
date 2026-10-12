#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PROJECT="gitea-it-${RANDOM}"
RESTORE_PROJECT="${PROJECT}-restore"
NET="${PROJECT}-proxy"
cleanup(){
  for project in "$PROJECT" "$RESTORE_PROJECT"; do
    docker compose --project-name "$project" --env-file "$TMP/.env" -f "$ROOT/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker run --rm -v "$TMP:/test" alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 rm -rf /test >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/data" "$TMP/pg" "$TMP/staging" "$TMP/restic"
docker network create "$NET" >/dev/null
cp "$ROOT/.env.example" "$TMP/.env"
python3 - "$TMP/.env" "$TMP" "$PROJECT" "$NET" <<'PY'
from pathlib import Path
import sys
p, root, project, net = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
s=p.read_text()
values={"PARSER_PROBE":"value $with ${literal} # chars and spaces", "DATA_DIR":root/"data", "PGDATA_DIR":root/"pg", "STAGING_DIR":root/"staging", "GITEA_DOMAIN":"localhost", "PROXY_NETWORK":net, "COMPOSE_PROJECT_NAME":project, "SSH_HOST_PORT":str(24000 + __import__("random").randrange(10000)), "HTTP_HOST_PORT":str(30000 + __import__("random").randrange(10000)), "GITEA_IMAGE":"docker.gitea.com/gitea", "POSTGRES_IMAGE":"postgres", "RESTIC_REPOSITORY":f"local:{root}/restic", "RESTIC_PASSWORD":"integration-test-password", "POSTGRES_PASSWORD":"'literal $with ${symbols} # and spaces'", "GITEA_SECRET_KEY":"integration-gitea-secret-key-xxxxxxxx", "GITEA_INTERNAL_TOKEN":"integration-gitea-internal-token-xxxx", "ADMIN_EMAIL":"admin@example.test", "ADMIN_PASSWORD":"Integration-Password-2026", "KEEP_DAILY":"1", "KEEP_WEEKLY":"1", "KEEP_MONTHLY":"1"}
lines=[]
for line in s.splitlines():
    key=line.split("=",1)[0]
    if key in values: line=f"{key}={values[key]}"
    lines.append(line)
p.write_text("\n".join(lines)+"\n")
PY
PARSED_DB_PASSWORD="$(python3 "$ROOT/scripts/load-env.py" "$TMP/.env" | python3 -c 'import sys; d=dict(x.split(b"=",1) for x in sys.stdin.buffer.read().split(b"\0") if x); print(d[b"POSTGRES_PASSWORD"].decode())')"
COMPOSE_DB_PASSWORD="$(docker compose --project-name "$PROJECT" --env-file "$TMP/.env" -f "$ROOT/compose.yaml" config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["gitea"]["environment"]["GITEA__database__PASSWD"])')"
# Compose output escapes dollar signs for a later interpolation pass; restoring those escapes matches the literal loader value.
COMPOSE_DB_PASSWORD="${COMPOSE_DB_PASSWORD//\$\$/\$}"
test "$COMPOSE_DB_PASSWORD" = "$PARSED_DB_PASSWORD"
HTTP_PORT="$(sed -n 's/^HTTP_HOST_PORT=//p' "$TMP/.env")"
chmod 600 "$TMP/.env"
export RESTIC_REPOSITORY="local:$TMP/restic" RESTIC_PASSWORD=integration-test-password
MANAGE="$ROOT/manage.sh"
# Run a copy so test-only config and volumes cannot touch a developer instance.
mkdir -p "$TMP/project"
cp -R "$ROOT/compose.yaml" "$ROOT/manage.sh" "$ROOT/scripts" "$TMP/project/"
cp "$TMP/.env" "$TMP/project/.env"
MANAGE="$TMP/project/manage.sh"
# Fresh Compose startup must fail closed before explicit initialization.
if docker compose --project-name "$PROJECT" --env-file "$TMP/.env" -f "$ROOT/compose.yaml" up -d; then
  echo "Compose unexpectedly started a fresh instance without bootstrap authorization." >&2
  exit 1
fi
if docker compose --project-name "$PROJECT" --env-file "$TMP/.env" -f "$ROOT/compose.yaml" ps --status running --services | grep -qx gitea; then
  echo "Bootstrap gate allowed Gitea to run on empty storage." >&2
  exit 1
fi
restic init
"$MANAGE" init --fresh --confirm-fresh
# Wait for HTTP and make data operations through Gitea API only after the administrator was initialized.
for _ in {1..60}; do curl -fsS http://127.0.0.1:${HTTP_PORT}/api/healthz >/dev/null 2>&1 && break || sleep 2; done
curl -fsS -u "admin:Integration-Password-2026" -H 'Content-Type: application/json' \
  -d '{"name":"restore-smoke","private":true,"auto_init":true,"default_branch":"main"}' \
  http://127.0.0.1:${HTTP_PORT}/api/v1/user/repos >/dev/null
cd "$TMP"
git clone http://admin:Integration-Password-2026@127.0.0.1:${HTTP_PORT}/admin/restore-smoke.git clone
cd clone
echo "backup restore smoke" > README.md
git config user.email admin@example.test; git config user.name admin
git add README.md; git commit -m smoke; git push origin main
"$MANAGE" backup now
"$MANAGE" status
"$MANAGE" backup list
"$MANAGE" backup verify
# Invalid repository credentials must fail closed without creating a new instance.
python3 - "$TMP/project/.env" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace("RESTIC_PASSWORD=integration-test-password", "RESTIC_PASSWORD=wrong-password"))
PY
if "$MANAGE" backup list; then echo "Backup listing unexpectedly accepted the wrong password." >&2; exit 1; fi
if RESTORE_CONFIRM=gitea-prod:latest "$MANAGE" restore --latest; then echo "Restore unexpectedly accepted the wrong password." >&2; exit 1; fi
python3 - "$TMP/project/.env" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace("RESTIC_PASSWORD=wrong-password", "RESTIC_PASSWORD=integration-test-password"))
PY
# Restore gets its own entirely separate paths and Compose project but identical Gitea port exposure needs stop of source first.
docker compose --project-name "$PROJECT" --env-file "$TMP/.env" -f "$TMP/project/compose.yaml" down
python3 - "$TMP/project/.env" "$TMP" "$PROJECT" "$NET" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); root=Path(sys.argv[2]); old=sys.argv[3]; net=sys.argv[4]
s=p.read_text().replace(f"COMPOSE_PROJECT_NAME={old}",f"COMPOSE_PROJECT_NAME={old}-restore").replace(f"{root}/data",f"{root}/restore-data").replace(f"{root}/pg",f"{root}/restore-pg").replace(f"{root}/staging",f"{root}/restore-staging")
p.write_text(s)
for d in ["restore-data","restore-pg","restore-staging"]: (root/d).mkdir(exist_ok=True)
PY
# Simulate an interrupted database import: rollback must clear only the new target and allow a retry.
mkdir -p "$TMP/failbin"
REAL_DOCKER="$(command -v docker)"
if [[ "$(basename "$REAL_DOCKER")" == docker ]]; then REAL_DOCKER="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REAL_DOCKER")"; fi
export REAL_DOCKER
cat > "$TMP/failbin/docker" <<'SH'
#!/bin/sh
if [ "${1:-}" = compose ]; then
  for arg in "$@"; do
    if [ "$arg" = pg_restore ]; then exit 42; fi
  done
fi
exec "$REAL_DOCKER" "$@"
SH
chmod +x "$TMP/failbin/docker"
if PATH="$TMP/failbin:$PATH" MANAGE_LOCK_INHERITED=true RESTORE_CONFIRM=gitea-prod:latest "$MANAGE" restore --latest; then
  echo "Injected failed restore unexpectedly succeeded." >&2; exit 1
fi
test ! -e "$TMP/restore-data"
test ! -e "$TMP/restore-pg"
test ! -e "$TMP/restore-staging/restore"
RESTORE_CONFIRM=gitea-prod:latest "$MANAGE" restore --latest
for _ in {1..60}; do curl -fsS http://127.0.0.1:${HTTP_PORT}/api/healthz >/dev/null 2>&1 && break || sleep 2; done
git -C "$TMP" clone http://admin:Integration-Password-2026@127.0.0.1:${HTTP_PORT}/admin/restore-smoke.git restored-clone
test "$(cat "$TMP/restored-clone/README.md")" = 'backup restore smoke'
echo "post-restore write" >> "$TMP/restored-clone/README.md"
git -C "$TMP/restored-clone" config user.email admin@example.test
git -C "$TMP/restored-clone" config user.name admin
git -C "$TMP/restored-clone" add README.md
git -C "$TMP/restored-clone" commit -m 'post-restore push'
git -C "$TMP/restored-clone" push origin main
# Retention is a logical-service policy, not separate per host or path.
printf "snapshot A\n" > "$TMP/snapshot-a"
printf "snapshot B\n" > "$TMP/snapshot-b"
restic backup "$TMP/snapshot-a" --tag gitea-prod --host old-vps
restic backup "$TMP/snapshot-b" --tag gitea-prod --host samovar
"$MANAGE" backup prune --confirm
SNAPSHOT_COUNT="$(restic snapshots --json --tag gitea-prod | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
test "$SNAPSHOT_COUNT" = 1
