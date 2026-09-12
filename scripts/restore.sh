#!/usr/bin/env bash
# Restores a backup made by backup.sh: replays both Postgres dumps and
# re-extracts the Redis/MiniStack volume tarballs. Destructive — overwrites
# whatever is currently in the stack's databases and volumes.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="delite-local-dev"
SRC="${1:-}"

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "Usage: restore.sh <backup_dir>"
  echo "  (the directory backup.sh printed, containing delite_hr.sql etc.)"
  exit 1
fi

for f in delite_hr.sql delite_hr_apps.sql redis_data.tar.gz hr_redis_data.tar.gz ministack_data.tar.gz; do
  [ -f "$SRC/$f" ] || { echo "Missing $SRC/$f — is this a valid backup dir?"; exit 1; }
done

echo "Restoring from $SRC into the '${PROJECT}' stack. This overwrites current data."
read -r -p "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

# Bring up postgres alone first so it exists (creates a fresh empty volume
# if it was wiped), stop the others so we can safely overwrite their files.
docker compose up -d postgres
docker compose stop redis hr_redis ministack 2>/dev/null || true

echo "==> Postgres: delite_hr"
docker exec -i "${PROJECT}-postgres-1" psql -U postgres -d delite_hr < "$SRC/delite_hr.sql"

echo "==> Postgres: delite_hr_apps"
docker exec -i "${PROJECT}-postgres-1" psql -U postgres -d delite_hr_apps < "$SRC/delite_hr_apps.sql"

for vol in redis_data hr_redis_data ministack_data; do
  echo "==> Volume: ${PROJECT}_${vol}"
  docker run --rm \
    -v "${PROJECT}_${vol}:/data" \
    -v "$SRC:/backup" \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/${vol}.tar.gz -C /data"
done

echo "==> Starting the full stack"
docker compose up -d

echo "Done."
