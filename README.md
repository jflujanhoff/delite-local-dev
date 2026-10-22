# delite-local-dev

Local development orchestration for the Delite HR platform. Expects the following repos cloned side by side:

```
11.Delite AI/
├── delite-agent-service/  (general-purpose agent platform — projects/documents/chat/generic tools)
├── delite-app-frontend/
├── delite-hr-service/     (HR/job-application domain — see its README)
└── delite-local-dev/      ← you are here
```

`delite-agent-service` and `delite-hr-service` are two separate backend services, split apart per the plan at `/Users/lujan/.claude/plans/majestic-noodling-conway.md` — `delite-agent-service` owns projects/documents/chat/generic tools, `delite-hr-service` owns the HR domain (company research, keywords, analytics, applications). They run as two separate processes below, each with its own database, and talk to each other over REST/MCP rather than sharing code.

## Setup

1. Make sure all repos are cloned and `delite-agent-service/.env` + `delite-hr-service/.env` exist.
2. Start everything:
   ```bash
   chmod +x start.sh
   ./start.sh
   ```

Everything — Postgres, Redis, MiniStack (S3 emulator), the agent-service backend + its Celery worker, the hr-service backend + its own dedicated Redis and Celery worker, Flower, and the frontend — runs as a Docker container. There's nothing to `npm install` on the host; the frontend's dependencies install inside its own container image.

`delite-hr-service` gets its own Postgres database (`delite_hr_apps`) on the same Postgres instance as `delite-agent-service`'s `delite_hr` database — separate databases, not a shared schema. This is created automatically by `postgres-init/create-hr-service-db.sh` on first container init; if you already have an existing `postgres_data` volume from before this database existed, run `./start.sh --reset` (wipes it) or create it by hand: `docker compose exec postgres psql -U postgres -c "CREATE DATABASE delite_hr_apps;"`.

File storage uses the same `boto3`/S3 code path as production, pointed at MiniStack instead of real AWS (`STORAGE_BACKEND=s3`, `S3_ENDPOINT_URL=http://ministack:4566` in `delite-agent-service/.env` and `delite-hr-service/.env`) — a free, MIT-licensed drop-in for LocalStack Community, which was archived 2026-03-23. Deploying to real AWS later is an env-var change (bucket, region, credentials/IAM role) plus a data copy (`aws s3 sync` from the MiniStack bucket to the real one), not a code change. Data genuinely persists across restarts now (`S3_PERSIST=1`, verified by killing and recreating the container against the same volume) — LocalStack's equivalent flag never actually worked on Community Edition.

## Commands

| Command | Description |
|---|---|
| `./start.sh` | Start everything (Docker) |
| `./start.sh --build` | Rebuild images then start |
| `./start.sh --restart` | Stop → rebuild → start fresh |
| `./start.sh --stop` | Stop all services |
| `./start.sh --reset` | Wipe DB, storage, LocalStack state, and Docker volumes |
| `./start.sh --logs` | Start then tail all logs |
| `./start.sh --backend-only` | Backend services only (no frontend) |
| `./start.sh --frontend-only` | Frontend only |

## URLs

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| API (delite-agent-service) | http://localhost:8000 |
| HR API (delite-hr-service) | http://localhost:8001 |
| Flower (Celery) | http://localhost:5555 |
| LocalStack (S3) | http://localhost:4566 |
| Postgres | localhost:5432 (`delite_hr` + `delite_hr_apps` databases) |
| Redis (agent-service) | localhost:6379 |
| Redis (hr-service) | localhost:6381 |
| OpenSandbox (code workspace) | localhost:8090 (loopback only) |

## Code workspace (optional)

The agent's `run_code`, `workspace_add_document` and `workspace_save_file` tools run model-written Python in one sandbox per conversation, through the `opensandbox` service. They are off unless `../delite-agent-service/.env` sets:

```
CODE_WORKSPACE_PROVIDER=opensandbox
OPENSANDBOX_SERVER_API_KEY=<any long random string>
```

Build the image the sandboxes run (once, and again after changing its `requirements.txt`):

```bash
../delite-agent-service/backend/agent/tools/sandbox/workspace_image/build.sh
```

This is a **local-only** setup: on OpenSandbox's Docker runtime, code inside a sandbox can reach a root daemon in its own container. Network access is denied and no secrets go in, which is fine on a laptop, but production uses a different provider. See `opensandbox/config.toml` for the layout.
