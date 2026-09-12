#!/bin/bash
set -e

cd "$(dirname "$0")"

usage() {
  echo "---------------------------------------------------------------------"
  echo " FIRST TIME SETUP"
  echo "---------------------------------------------------------------------"
  echo "  Nothing to install locally — frontend deps install inside the"
  echo "  container on first build."
  echo ""
  echo "---------------------------------------------------------------------"
  echo " START"
  echo "---------------------------------------------------------------------"
  echo "  ./start.sh                   Start everything (Docker)"
  echo "  ./start.sh --logs            Start everything, then tail all logs"
  echo "  ./start.sh --build           Rebuild Docker images, then start"
  echo "  ./start.sh --build-logs      Rebuild Docker images, start, then tail all logs"
  echo "  ./start.sh --restart         Stop → rebuild → start fresh"
  echo "  ./start.sh --restart-logs    Stop → rebuild → start fresh, then tail all logs"
  echo "  ./start.sh --backend-only    Start backend services only (no frontend)"
  echo "  ./start.sh --frontend-only   Start frontend service only"
  echo ""
  echo "---------------------------------------------------------------------"
  echo " STOP"
  echo "---------------------------------------------------------------------"
  echo "  ./start.sh --stop            Stop all services              (data preserved)"
  echo "  ./start.sh --reset           ⚠️  PERMANENTLY wipe DB, storage, LocalStack, and Docker volumes"
  echo ""
  echo "---------------------------------------------------------------------"
  echo " LOGS"
  echo "---------------------------------------------------------------------"
  echo "  docker compose logs -f               Tail all logs"
  echo "  docker compose logs -f backend       Tail API logs only"
  echo "  docker compose logs -f frontend      Tail frontend logs only"
  echo "  docker compose logs -f celery_worker Tail Celery worker logs"
  echo ""
  echo "---------------------------------------------------------------------"
  echo " URLS"
  echo "---------------------------------------------------------------------"
  echo "  Frontend   → http://localhost:3000"
  echo "  API        → http://localhost:8000"
  echo "  HR API     → http://localhost:8001"
  echo "  Flower     → http://localhost:5555"
  echo "  LocalStack → http://localhost:4566"
  echo "---------------------------------------------------------------------"
}

BACKEND_SERVICES="postgres redis ministack ministack-init backend celery_worker flower hr_redis hr_service hr_celery_worker"
FRONTEND_SERVICE="frontend"

TAIL_LOGS=false
BACKEND_ONLY=false
FRONTEND_ONLY=false

for arg in "$@"; do
  [[ "$arg" == "--logs" ]]          && TAIL_LOGS=true
  [[ "$arg" == "--backend-only" ]]  && BACKEND_ONLY=true
  [[ "$arg" == "--frontend-only" ]] && FRONTEND_ONLY=true
done

services_to_start() {
  if $BACKEND_ONLY; then
    echo "$BACKEND_SERVICES"
  elif $FRONTEND_ONLY; then
    echo "$FRONTEND_SERVICE"
  else
    echo "$BACKEND_SERVICES $FRONTEND_SERVICE"
  fi
}

# Frees a host port before Docker tries to bind it — lets start.sh and a
# native `npm run dev` / `uvicorn` process be used interchangeably without a
# manual `lsof`/`kill` step whenever you switch between the two. Only called
# for ports whose service is about to be (re)started, so it never touches an
# unrelated process on a port this stack isn't asking for.
#
# Never kills a Docker-owned process: on macOS, Docker Desktop routes every
# container's port mapping through one shared process (com.docker.backend /
# vpnkit), not a PID per port — sending it a kill signal for "just this port"
# takes the whole daemon down (confirmed the hard way). If the holder is
# Docker, it's almost certainly this same compose project's own container
# from a prior run, which `docker compose up -d` already recreates cleanly on
# its own — so we just skip and let it proceed.
free_port() {
  local port="$1" label="$2" pid comm
  pid=$(lsof -ti tcp:"$port" -sTCP:LISTEN 2>/dev/null || true)
  [[ -z "$pid" ]] && return 0
  comm=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$comm" in
    *[Dd]ocker*|*vpnkit*|*com.docke*)
      echo "Port $port ($label) is held by Docker itself (PID $pid) — leaving it alone; docker compose up will reuse/recreate its own container."
      return 0
      ;;
  esac
  echo "Port $port ($label) is held by PID $pid ($comm) outside Docker — stopping it so the container can bind."
  kill "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
}

# delite-agent-service also ships its own standalone docker-compose.yml (for
# running that one repo in isolation) that claims the same host ports this
# stack does (5432 Postgres, 6379 Redis, 8000 API, 5555 Flower) — starting
# this stack while that one is up fails on port collision. Mirrors the guard
# in ../delite-agent-service/start.sh, in the other direction.
guard_against_standalone_agent_service() {
  local running
  running=$(docker ps --filter "name=delite-agent-service-" --format "{{.Names}}" 2>/dev/null || true)
  if [[ -n "$running" ]]; then
    echo "⚠️  The standalone delite-agent-service stack is already running — it uses the"
    echo "    same ports (5432 Postgres, 6379 Redis, 8000 API, 5555 Flower) and will collide."
    echo ""
    echo "    Stop it first (containers only — its database and files are untouched):"
    echo "      cd ../delite-agent-service && docker compose down"
    echo ""
    exit 1
  fi
}

# Wraps `docker compose up -d` with a preflight port check for whichever
# services are being started, so `./start.sh` always succeeds even if a
# host-level dev server from a previous session is still holding the port.
start_services() {
  for svc in "$@"; do
    case "$svc" in
      frontend)   free_port 3000 "frontend" ;;
      backend)    free_port 8000 "backend" ;;
      hr_service) free_port 8001 "hr_service" ;;
    esac
  done
  docker compose up -d "$@"

  # Safety net, not root-cause prevention: some images (flower, ministack —
  # see the tmpfs mounts on those services above) bake in a VOLUME path with
  # nothing explicitly mounted there, so Docker silently creates a fresh
  # anonymous volume every time the container is recreated, and none of them
  # ever get cleaned up on their own — that's how this project accumulated
  # 98 stray volumes. This can't remove anything still attached to a
  # container (running or stopped), so it's safe to run unconditionally; it
  # just guarantees whatever orphans *do* get created — from these two
  # images or a future one with the same pattern — never get to pile up.
  docker volume prune -f >/dev/null
}

print_urls() {
  echo ""
  echo "Services running:"
  echo "  Frontend   → http://localhost:3000"
  echo "  API        → http://localhost:8000"
  echo "  HR API     → http://localhost:8001"
  echo "  Flower     → http://localhost:5555"
  echo "  LocalStack → http://localhost:4566"
  echo ""
}

case "$1" in
  --build|--build-logs)
    guard_against_standalone_agent_service
    echo "Building images..."
    docker compose build
    echo "Starting services (data preserved — existing volumes are reused)..."
    start_services $(services_to_start)
    [[ "$1" == "--build-logs" ]] && TAIL_LOGS=true
    ;;
  --restart|--restart-logs)
    guard_against_standalone_agent_service
    echo "Stopping services — containers only, database and files are preserved..."
    docker compose down
    echo "Rebuilding images..."
    docker compose build
    echo "Starting services (data preserved — existing volumes are reused)..."
    start_services $(services_to_start)
    [[ "$1" == "--restart-logs" ]] && TAIL_LOGS=true
    ;;
  --stop)
    echo "Stopping services — containers only, database and files are preserved..."
    docker compose down
    echo "All services stopped. Data untouched — run ./start.sh to bring it all back."
    exit 0
    ;;
  --reset)
    guard_against_standalone_agent_service
    echo "⚠️  This will PERMANENTLY DELETE the database, all storage files, LocalStack"
    echo "    state, and Docker volumes — unlike --stop/--restart, this does NOT preserve data."
    read -r -p "Are you sure? (yes/N) " confirm
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted — nothing was touched."
      exit 0
    fi
    echo "Stopping services and wiping volumes..."
    docker compose down -v
    echo "Deleting storage files..."
    rm -rf "../delite-agent-service/storage/*"
    echo "Rebuilding images..."
    docker compose build
    echo "Starting fresh..."
    start_services $(services_to_start)
    ;;
  --frontend-only)
    echo "Starting frontend..."
    start_services frontend
    print_urls
    exit 0
    ;;
  --backend-only)
    guard_against_standalone_agent_service
    echo "Starting backend services..."
    start_services $BACKEND_SERVICES
    ;;
  --logs)
    guard_against_standalone_agent_service
    echo "Starting services (data preserved — existing volumes are reused)..."
    start_services $(services_to_start)
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  "")
    guard_against_standalone_agent_service
    echo "Starting services (data preserved — existing volumes are reused)..."
    start_services $(services_to_start)
    ;;
  *)
    echo "Unknown flag: $1"
    usage
    exit 1
    ;;
esac

print_urls

if $TAIL_LOGS; then
  echo "Tailing logs (Ctrl+C to stop tailing — services keep running)..."
  docker compose logs -f
else
  echo "Logs:     docker compose logs -f"
  echo "Stop all: ./start.sh --stop"
fi
