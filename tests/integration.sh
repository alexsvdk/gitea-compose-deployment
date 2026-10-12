#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PROJECT="gitea-it-${RANDOM}"
NET="${PROJECT}-proxy"
cleanup(){
  docker compose --project-name "$PROJECT" --env-file "$TMP/.env" -f "$ROOT/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
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
values={"DATA_DIR":root/"data", "PGDATA_DIR":root/"pg", "STAGING_DIR":root/"staging", "GITEA_DOMAIN":"localhost", "PROXY_NETWORK":net, "COMPOSE_PROJECT_NAME":project, "SSH_HOST_PORT":str(24000 + __import__("random").randrange(10000)), "HTTP_HOST_PORT":str(30000 + __import__("random").randrange(10000)), "GITEA_IMAGE":"docker.gitea.com/gitea", "POSTGRES_IMAGE":"postgres", "RESTIC_REPOSITORY":f"local:{root}/restic", "RESTIC_PASSWORD":"integration-test-password", "POSTGRES_PASSWORD":"integration-db-password-xxxxxxxx", "GITEA_SECRET_KEY":"integration-gitea-secret-key-xxxxxxxx", "GITEA_INTERNAL_TOKEN":"integration-gitea-internal-token-xxxx", "ADMIN_EMAIL":"admin@example.test", "ADMIN_PASSWORD":"Integration-Password-2026"}
lines=[]
for line in s.splitlines():
    key=line.split("=",1)[0]
    if key in values: line=f"{key}={values[key]}"
    lines.append(line)
p.write_text("\n".join(lines)+"\n")
PY
HTTP_PORT="$(sed -n 's/^HTTP_HOST_PORT=//p' "$TMP/.env")"
chmod 600 "$TMP/.env"
export RESTIC_REPOSITORY="local:$TMP/restic" RESTIC_PASSWORD=integration-test-password
MANAGE="$ROOT/manage.sh"
# Manage script project config currently .env lives beside script; run in a worktree copy so isolation uses the test env.
restic init
mkdir -p "$TMP/project"
cp -R "$ROOT/compose.yaml" "$ROOT/manage.sh" "$ROOT/scripts" "$TMP/project/"
cp "$TMP/.env" "$TMP/project/.env"
MANAGE="$TMP/project/manage.sh"
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
