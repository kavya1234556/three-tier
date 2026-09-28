#!/usr/bin/env bash
# Back up the MongoDB database running in the "mongo" compose service using mongodump.
# Produces a gzipped archive named <db>_<YYYY-MM-DD_HH-MM-SS>.archive.gz
#
# Usage:   ./scripts/mongo-backup.sh
# Env:     BACKUP_DIR (default ./backups), RETENTION_DAYS (default 7),
#          MONGO_SERVICE (default mongo), plus MONGO_DB from .env
# Cron:    0 2 * * * cd /path/to/three-tier && ./scripts/mongo-backup.sh >> backups/backup.log 2>&1
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

MONGO_DB="${MONGO_DB:?MONGO_DB must be set (see .env)}"
MONGO_SERVICE="${MONGO_SERVICE:-mongo}"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_FILE="$BACKUP_DIR/${MONGO_DB}_${TIMESTAMP}.archive.gz"
TMP_FILE="$BACKUP_FILE.partial"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'rm -f "$TMP_FILE"' EXIT

mkdir -p "$BACKUP_DIR"

if ! docker compose ps --status running --services | grep -qx "$MONGO_SERVICE"; then
  log "ERROR: compose service '$MONGO_SERVICE' is not running"
  exit 1
fi

log "Starting backup of '$MONGO_DB' -> $BACKUP_FILE"

# Credentials are read from the container's own env, so they never appear in host process args.
docker compose exec -T "$MONGO_SERVICE" sh -c '
  exec mongodump \
    --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --db "$1" \
    --archive --gzip --quiet
' _ "$MONGO_DB" > "$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
  log "ERROR: backup file is empty"
  exit 1
fi

mv "$TMP_FILE" "$BACKUP_FILE"
log "Backup complete ($(du -h "$BACKUP_FILE" | cut -f1))"

deleted=$(find "$BACKUP_DIR" -name "${MONGO_DB}_*.archive.gz" -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
log "Removed $deleted backup(s) older than $RETENTION_DAYS days"
