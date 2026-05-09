#!/usr/bin/env bash
# ============================================================================
# run.sh — one-shot launcher for the Restaurant Ordering System.
#
# Поднимает:
#   1) проверяет что PostgreSQL доступен
#   2) FastAPI backend (uvicorn) на :8000
#   3) Next.js frontend на :3000
#
# Логи пишутся в .run/backend.log и .run/frontend.log.
# PID-ы — в .run/backend.pid и .run/frontend.pid.
#
# Остановить всё: ./run.sh stop
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNDIR="$ROOT/.run"
mkdir -p "$RUNDIR"

if [ -f "$ROOT/.env" ]; then
    set -a
    source "$ROOT/.env"
    set +a
fi

# ---- Postgres connection (override via env) -------------------------------
: "${POSTGRES_HOST:=127.0.0.1}"
: "${POSTGRES_PORT:=5433}"
: "${POSTGRES_USER:=ros_admin}"
: "${POSTGRES_PASSWORD:=}"
: "${POSTGRES_DB:=restaurant_ordering}"
: "${BACKEND_PORT:=8000}"
: "${FRONTEND_PORT:=3000}"

export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT" PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB"
[ -n "$POSTGRES_PASSWORD" ] && export PGPASSWORD="$POSTGRES_PASSWORD"

cmd="${1:-start}"

stop_service() {
    local name="$1"
    local pidfile="$RUNDIR/$name.pid"
    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "  stopping $name (pid $pid)"
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
}

case "$cmd" in
    stop)
        echo "[run] stopping services…"
        stop_service backend
        stop_service frontend
        echo "[run] done."
        exit 0
        ;;
    status)
        for name in backend frontend; do
            pidfile="$RUNDIR/$name.pid"
            if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                echo "  $name: RUNNING (pid $(cat "$pidfile"))"
            else
                echo "  $name: stopped"
            fi
        done
        exit 0
        ;;
    logs)
        tail -f "$RUNDIR/backend.log" "$RUNDIR/frontend.log"
        exit 0
        ;;
    start|"")
        ;;
    *)
        echo "usage: $0 [start|stop|status|logs]"
        exit 1
        ;;
esac

echo "[run] 1/4  checking Postgres at ${POSTGRES_HOST}:${POSTGRES_PORT}…"
if ! pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; then
    echo "  ✗ Postgres is not reachable."
    echo "    Start it first (brew services start postgresql@16 / docker compose up -d)."
    exit 1
fi
echo "  ✓ Postgres is up"

echo "[run] 2/4  checking schema & seed…"
if ! psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1 FROM tenants LIMIT 1;" | grep -q 1; then
    echo "  → Database is empty, seeding data…"
    (cd "$ROOT" && backend/venv/bin/python3 scripts/seed_faker.py >/dev/null || true)
else
    echo "  ✓ database is already seeded (skipped)"
fi

# ---- stop any previous run -------------------------------------------------
stop_service backend
stop_service frontend

echo "[run] 3/4  starting backend on :${BACKEND_PORT}…"
(
    cd "$ROOT/backend"
    nohup venv/bin/python3 -m uvicorn app.main:app --host 0.0.0.0 --port "$BACKEND_PORT" \
        > "$RUNDIR/backend.log" 2>&1 &
    echo $! > "$RUNDIR/backend.pid"
)
sleep 1.5
if ! kill -0 "$(cat "$RUNDIR/backend.pid")" 2>/dev/null; then
    echo "  ✗ backend failed to start. Tail of log:"
    tail -30 "$RUNDIR/backend.log"
    exit 1
fi
echo "  ✓ backend pid $(cat "$RUNDIR/backend.pid")"

echo "[run] 4/4  starting frontend on :${FRONTEND_PORT}…"
if [ ! -d "$ROOT/frontend/node_modules" ]; then
    echo "  → installing npm deps (first run)…"
    (cd "$ROOT/frontend" && npm install --silent)
fi
(
    cd "$ROOT/frontend"
    NEXT_PUBLIC_API_URL="http://localhost:$BACKEND_PORT" \
    nohup npm run dev -- --port "$FRONTEND_PORT" \
        > "$RUNDIR/frontend.log" 2>&1 &
    echo $! > "$RUNDIR/frontend.pid"
)
sleep 2
echo "  ✓ frontend pid $(cat "$RUNDIR/frontend.pid")"

cat <<EOF

╭─────────────────────────────────────────────────────────────╮
│  Restaurant Ordering System — up                            │
├─────────────────────────────────────────────────────────────┤
│  Backend API   →  http://localhost:$BACKEND_PORT             │
│  Swagger UI    →  http://localhost:$BACKEND_PORT/docs        │
│  Frontend      →  http://localhost:$FRONTEND_PORT            │
│                                                             │
│  Login:  owner.alpha@demo.test / demo1234                   │
│                                                             │
│  Logs:   ./run.sh logs                                      │
│  Status: ./run.sh status                                    │
│  Stop:   ./run.sh stop                                      │
╰─────────────────────────────────────────────────────────────╯
EOF
