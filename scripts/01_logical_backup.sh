#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: bash scripts/01_logical_backup.sh [source_db] [restore_test_db]
SOURCE_DB="${1:-bootcamp}"
TEST_DB="${2:-bootcamp_check}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
DUMP_FILE="$BACKUP_DIR/$SOURCE_DB-$(date +%Y%m%d_%H%M%S).dump"

command -v pg_dump >/dev/null || { echo "pg_dump not found; install PostgreSQL client tools." >&2; exit 1; }
command -v pg_restore >/dev/null || { echo "pg_restore not found; install PostgreSQL client tools." >&2; exit 1; }
command -v createdb >/dev/null || { echo "createdb not found; install PostgreSQL client tools." >&2; exit 1; }
command -v psql >/dev/null || { echo "psql not found; install PostgreSQL client tools." >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$TEST_DB'" | grep -q 1; then
  echo "Refusing to overwrite existing test database '$TEST_DB'." >&2
  echo "Choose another test database name or inspect the existing database first." >&2
  exit 1
fi

echo "Creating custom-format logical backup: $DUMP_FILE"
pg_dump --format=custom --file="$DUMP_FILE" "$SOURCE_DB"

echo "Listing backup contents:"
pg_restore --list "$DUMP_FILE" | head -n 20

echo "Creating isolated restore-test database: $TEST_DB"
createdb "$TEST_DB"
if ! pg_restore --verbose --exit-on-error --dbname="$TEST_DB" "$DUMP_FILE"; then
  echo "Restore failed. The test database '$TEST_DB' has been left for inspection." >&2
  exit 1
fi

echo "Restore completed. Tables in $TEST_DB:"
psql -d "$TEST_DB" -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY schemaname, tablename;"
echo "Backup verified: $DUMP_FILE"
echo "When you have inspected the test database, remove it manually with: dropdb '$TEST_DB'"
