#!/usr/bin/env bash
# Backs up everything the local dev stack persists: both Postgres databases
# (logical dump, safe to take while containers are running) plus the raw
# Redis and MiniStack (S3) volumes. Excludes frontend_node_modules/
# frontend_next_cache — build caches, not data.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="delite-local-dev"
DEST="${1:-$HOME/delite-backups/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$DEST"

echo "Backing up to $DEST"

echo "==> Postgres: delite_hr"
docker exec "${PROJECT}-postgres-1" pg_dump -U postgres -d delite_hr --clean --if-exists > "$DEST/delite_hr.sql"

echo "==> Postgres: delite_hr_apps"
docker exec "${PROJECT}-postgres-1" pg_dump -U postgres -d delite_hr_apps --clean --if-exists > "$DEST/delite_hr_apps.sql"

for vol in redis_data hr_redis_data ministack_data; do
  echo "==> Volume: ${PROJECT}_${vol}"
  docker run --rm \
    -v "${PROJECT}_${vol}:/data:ro" \
    -v "$DEST:/backup" \
    alpine tar czf "/backup/${vol}.tar.gz" -C /data .
done

echo "Done. Contents:"
du -sh "$DEST"/* 2>/dev/null
