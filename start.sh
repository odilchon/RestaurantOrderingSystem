#!/usr/bin/env bash
# ============================================================================
# start.sh — быстрый запуск Restaurant Ordering System
# Использование: bash start.sh
# ============================================================================

PSQL="/usr/local/Cellar/postgresql@16/16.13/bin"
PYTHON_PATH="/Users/odiljonasmatov/Library/Python/3.9/bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "╭─────────────────────────────────────────────────╮"
echo "│     Restaurant Ordering System — Starting...    │"
echo "╰─────────────────────────────────────────────────╯"
echo ""

# 1. Проверить PostgreSQL
echo "▶ Checking PostgreSQL on port 5433..."
if ! "$PSQL/pg_isready" -p 5433 -h localhost -U ros_admin > /dev/null 2>&1; then
    echo -e "  ${YELLOW}PostgreSQL not running. Starting it...${NC}"
    /usr/local/Cellar/postgresql@16/16.13/bin/pg_ctl \
        -D /usr/local/var/postgresql@16 \
        -l /tmp/ros_pg.log \
        start > /dev/null 2>&1
    sleep 2
    if ! "$PSQL/pg_isready" -p 5433 -h localhost -U ros_admin > /dev/null 2>&1; then
        echo -e "  ${RED}✗ Could not start PostgreSQL. Check your installation.${NC}"
        exit 1
    fi
fi
echo -e "  ${GREEN}✓ PostgreSQL is up (port 5433)${NC}"

# 2. Проверить наличие uvicorn
export PATH="$PATH:$PYTHON_PATH"
if ! command -v uvicorn &> /dev/null; then
    echo -e "  ${RED}✗ uvicorn not found. Install it: pip3 install uvicorn${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ uvicorn found${NC}"

# 3. Запустить бэкенд
echo ""
echo "▶ Starting FastAPI backend..."
echo ""
echo "╭─────────────────────────────────────────────────╮"
echo "│  ✅  Server is starting up!                     │"
echo "│                                                 │"
echo "│  Swagger UI  →  http://localhost:8000/docs      │"
echo "│  Health      →  http://localhost:8000/health    │"
echo "│                                                 │"
echo "│  Login:  manager@plovpos.kg / password          │"
echo "│                                                 │"
echo "│  Press Ctrl+C to stop                          │"
echo "╰─────────────────────────────────────────────────╯"
echo ""

cd "$ROOT/backend"
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
