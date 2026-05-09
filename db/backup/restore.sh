#!/usr/bin/env bash
# ============================================================================
# restore.sh — Восстановление из custom-format дампа.
#
# Usage:
#   ./db/backup/restore.sh <dump_file>
#   ./db/backup/restore.sh latest      # берёт самый свежий dump из $BACKUP_DIR
#
# ВНИМАНИЕ: DROP DATABASE + CREATE DATABASE — полная замена.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=ros_admin}"
: "${POSTGRES_DB:=restaurant_ordering}"
: "${BACKUP_DIR:=$REPO_ROOT/backups}"

DUMP="${1:-latest}"

if [[ "$DUMP" == "latest" ]]; then
    DUMP="$(ls -1t "$BACKUP_DIR"/ros_${POSTGRES_DB}_*.dump 2>/dev/null | head -1 || true)"
    if [[ -z "$DUMP" ]]; then
        echo "[restore] ERROR: no dumps found in $BACKUP_DIR" >&2
        exit 1
    fi
fi

if [[ ! -f "$DUMP" ]]; then
    echo "[restore] ERROR: dump file not found: $DUMP" >&2
    exit 1
fi

echo "[restore] $(date -Iseconds) Restoring $DUMP → $POSTGRES_DB"
read -r -p "[restore] This will DROP DATABASE $POSTGRES_DB. Continue? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

export PGPASSWORD="${POSTGRES_PASSWORD:-}"

psql --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
     --dbname=postgres -v ON_ERROR_STOP=1 <<SQL
    SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();
    DROP DATABASE IF EXISTS $POSTGRES_DB;
    CREATE DATABASE $POSTGRES_DB;
SQL

pg_restore --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --no-owner --no-privileges \
    --jobs=4 \
    --verbose \
    "$DUMP" 2>&1 | tail -20

echo "[restore] $(date -Iseconds) Done."
