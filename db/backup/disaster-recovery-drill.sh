#!/usr/bin/env bash
# ============================================================================
# disaster-recovery-drill.sh
# Воспроизводимый тест полного цикла backup → destroy → restore → verify.
# Используется на защите проекта чтобы показать живую стратегию DR.
#
# Шаги:
#   1) Записать checksum всех таблиц (количество строк).
#   2) Сделать свежий pg_dump.
#   3) DROP DATABASE.
#   4) CREATE DATABASE + pg_restore.
#   5) Сравнить checksum — должно совпадать.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=ros_admin}"
: "${POSTGRES_DB:=restaurant_ordering}"
: "${BACKUP_DIR:=$(cd "$SCRIPT_DIR/../.." && pwd)/backups}"

export PGPASSWORD="${POSTGRES_PASSWORD:-}"

CHECKSUM_SQL="
SELECT table_name, (xpath('/row/c/text()',
                          query_to_xml('SELECT count(*) AS c FROM ' ||
                                       quote_ident(table_schema) || '.' || quote_ident(table_name),
                                       true, false, '')))[1]::text::bigint AS row_count
  FROM information_schema.tables
 WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
 ORDER BY table_name;
"

echo "[DR-DRILL] Step 1/5: capturing baseline row counts"
BEFORE="$(mktemp)"
psql --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
     --dbname="$POSTGRES_DB" -tAc "$CHECKSUM_SQL" > "$BEFORE"
echo "  Captured $(wc -l < "$BEFORE" | tr -d ' ') tables"

echo "[DR-DRILL] Step 2/5: creating backup"
"$SCRIPT_DIR/backup.sh"

echo "[DR-DRILL] Step 3/5: destroying database"
psql --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
     --dbname=postgres -v ON_ERROR_STOP=1 <<SQL
    SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();
    DROP DATABASE $POSTGRES_DB;
SQL
echo "  Database dropped"

echo "[DR-DRILL] Step 4/5: restoring from latest dump"
psql --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
     --dbname=postgres -c "CREATE DATABASE $POSTGRES_DB;"

LATEST="$(ls -1t "$BACKUP_DIR"/ros_${POSTGRES_DB}_*.dump | head -1)"
pg_restore --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" --no-owner --no-privileges --jobs=4 "$LATEST" 2>&1 | tail -5

echo "[DR-DRILL] Step 5/5: verifying row counts match"
AFTER="$(mktemp)"
psql --host="$POSTGRES_HOST" --port="$POSTGRES_PORT" --username="$POSTGRES_USER" \
     --dbname="$POSTGRES_DB" -tAc "$CHECKSUM_SQL" > "$AFTER"

if diff -q "$BEFORE" "$AFTER" > /dev/null; then
    echo "[DR-DRILL] ✓ SUCCESS: all row counts match"
    rm -f "$BEFORE" "$AFTER"
    exit 0
else
    echo "[DR-DRILL] ✗ MISMATCH:"
    diff "$BEFORE" "$AFTER" || true
    rm -f "$BEFORE" "$AFTER"
    exit 1
fi
