#!/bin/sh
set -eu
if [ -f /data/.deployment-ready ] && [ -s /data/gitea/conf/app.ini ] && [ -s /pgdata/PG_VERSION ]; then
  echo "Existing Gitea data is marked ready."
  exit 0
fi
if [ "${ALLOW_RESTORE:-false}" = true ] && [ -s /data/gitea/conf/app.ini ]; then
  echo "Explicit restore authorization for verified Gitea files."
  exit 0
fi
if [ "${ALLOW_FRESH:-false}" = true ] && [ -z "$(ls -A /data 2>/dev/null || true)" ]; then
  echo "Explicit fresh initialization is authorized for this Compose invocation."
  exit 0
fi
echo "Bootstrap gate refused startup: no completed deployment marker with valid data. Run manage.sh init/restore; do not start an empty instance." >&2
exit 1
