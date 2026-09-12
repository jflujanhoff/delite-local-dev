# Restoring a backup

A backup made by `backup.sh` is a folder containing:

- `delite_hr.sql` — full dump of the agent-service database (schema + data, self-contained: it drops old objects before recreating them)
- `delite_hr_apps.sql` — same, for the hr-service database
- `redis_data.tar.gz`, `hr_redis_data.tar.gz` — raw Redis volume contents (cache/Celery queues — not critical, but included)
- `ministack_data.tar.gz` — raw S3 (MiniStack) volume contents — uploaded files, documents, etc.

`restore.sh` automates all of the steps below. It is **destructive** — it overwrites whatever is currently in the stack's databases and volumes — so only run it when you actually mean to replace current state with the backup.

## When to use this

- You ran `./start.sh --reset` (wipes DB/storage/volumes) and want old data back.
- A Docker volume got deleted or corrupted.
- You're setting up the stack fresh on a new machine and want to seed it with existing data instead of starting empty.

## Steps (automated by `restore.sh`)

1. **Make sure the repos and stack exist.** Clone `delite-agent-service`, `delite-hr-service`, `delite-app-frontend`, `delite-local-dev` side by side as usual, and confirm `.env` files are in place (see `delite-local-dev/README.md`).

2. **Start the stack once** so images build and volumes exist:
   ```bash
   cd "delite-local-dev"
   ./start.sh
   ```

3. **Run the restore script**, pointing it at the backup folder:
   ```bash
   ./scripts/restore.sh /Users/lujan/delite-backups/20260912_221925
   ```
   It will:
   - Ask for a `yes` confirmation before touching anything.
   - Bring up `postgres` alone (creating a fresh empty volume if needed) and stop `redis` / `hr_redis` / `ministack` so their files can be safely overwritten.
   - Replay `delite_hr.sql` and `delite_hr_apps.sql` into Postgres via `psql`.
   - Wipe and re-extract each Redis/MiniStack volume from its `.tar.gz`.
   - Bring the full stack back up (`docker compose up -d`).

4. **Verify.** Check the frontend (`http://localhost:3000`) and API (`http://localhost:8000`, `http://localhost:8001`) come up and show the restored data. Spot-check a document/file upload to confirm MiniStack (S3) content came back too.

## Doing it by hand (if you don't trust the script, or need a partial restore)

Restore just one database:
```bash
docker exec -i delite-local-dev-postgres-1 psql -U postgres -d delite_hr < /path/to/backup/delite_hr.sql
```

Restore just one volume (stop the service using it first):
```bash
docker compose stop ministack
docker run --rm \
  -v delite-local-dev_ministack_data:/data \
  -v /path/to/backup:/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/ministack_data.tar.gz -C /data"
docker compose up -d ministack
```

## Notes

- Redis volumes (`redis_data`, `hr_redis_data`) hold Celery queues/cache, not source-of-truth data — safe to skip restoring these if you just want the databases and files back; the stack will simply start with empty queues.
- The dumps are Postgres-version-sensitive if you ever change the `postgres` image tag in `docker-compose.yml` (currently `postgres:16-alpine`) — restoring across major version changes may need `pg_dumpall`/upgrade steps instead of a plain restore.
- Keep at least one backup copy outside `~/delite-backups` (e.g. in Dropbox, or another disk) — a local-only backup doesn't help if the machine itself is lost.
