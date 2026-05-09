#!/usr/bin/env bash
# ============================================================================
# backup.sh — Logical backup via pg_dump (custom format).
#
# Usage:
#   ./db/backup/backup.sh                     # daily timestamped dump
#   BACKUP_DIR=/tmp/ros ./db/backup/backup.sh # override destination
#
# Retention: последние 7 суточных + 4 недельных держим, остальные удаляем.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:=ros_admin}"
: "${POSTGRES_DB:=restaurant_ordering}"
: "${BACKUP_DIR:=$REPO_ROOT/backups}"

mkdir -p "$BACKUP_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
OUT="$BACKUP_DIR/ros_${POSTGRES_DB}_${TS}.dump"

echo "[backup] $(date -Iseconds) Starting pg_dump → $OUT"

PGPASSWORD="${POSTGRES_PASSWORD:-}" pg_dump \
    --host="$POSTGRES_HOST" \
    --port="$POSTGRES_PORT" \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --format=custom \
    --compress=9 \
    --no-owner \
    --no-privileges \
    --verbose \
    --file="$OUT" 2>&1 | tail -20

SIZE="$(du -h "$OUT" | cut -f1)"
echo "[backup] Success: $OUT ($SIZE)"

# Retention: 7 daily dumps
cd "$BACKUP_DIR"
ls -1t ros_${POSTGRES_DB}_*.dump 2>/dev/null | tail -n +8 | while read -r old; do
    echo "[backup] Pruning old dump: $old"
    rm -f "$old"
done

echo "[backup] $(date -Iseconds) Done. Kept $(ls -1 ros_${POSTGRES_DB}_*.dump 2>/dev/null | wc -l | tr -d ' ') dumps."
