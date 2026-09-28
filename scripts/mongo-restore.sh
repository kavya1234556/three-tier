#!/usr/bin/env bash
# Restore a backup created by mongo-backup.sh.
# Usage: ./scripts/mongo-restore.sh backups/appdb_2026-01-01_02-00-00.archive.gz
set -euo pipefail

BACKUP_FILE="${1:?Usage: $0 <backup-file.archive.gz>}"
[[ -f "$BACKUP_FILE" ]] || { echo "File not found: $BACKUP_FILE" >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
MONGO_SERVICE="${MONGO_SERVICE:-mongo}"

docker compose exec -T "$MONGO_SERVICE" sh -c '
  exec mongorestore \
    --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --archive --gzip --drop
' < "$BACKUP_FILE"

echo "Restored $BACKUP_FILE"
