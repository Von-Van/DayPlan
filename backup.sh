#!/bin/bash
# ========================================
# DayPlan - Backup Script
# ========================================
# Creates a compressed, timestamped backup of the data file.
# Retains backups for the configured number of days.
#
# Usage:
#   ./backup.sh                          # Use defaults
#   DATA_FILE=./data.json ./backup.sh    # Override data file path
#
# Cron example (daily at 2 AM):
#   0 2 * * * /path/to/dayplan/backup.sh >> /path/to/dayplan/logs/backup.log 2>&1
#
set -euo pipefail

# ----------------------------------------
# Configuration
# ----------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_HOME="${APP_HOME:-$SCRIPT_DIR}"

# Load .env if present
if [ -f "$APP_HOME/.env" ]; then
    set -a
    source "$APP_HOME/.env"
    set +a
fi

DATA_FILE="${DATA_FILE_PATH:-${APP_HOME}/dayplan_data.json}"
BACKUP_DIR="${BACKUP_DIR:-${APP_HOME}/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/dayplan_${TIMESTAMP}.json"

# ----------------------------------------
# Functions
# ----------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - BACKUP - $1"
}

# ----------------------------------------
# Create backup
# ----------------------------------------
log "Starting backup..."

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Verify data file exists
if [ ! -f "$DATA_FILE" ]; then
    log "WARNING: Data file not found at $DATA_FILE"
    log "Nothing to back up. Exiting."
    exit 0
fi

# Copy data file
cp "$DATA_FILE" "$BACKUP_FILE"
log "Backup created: $BACKUP_FILE"

# Validate the backup is valid JSON
if python3 -c "import json; json.load(open('$BACKUP_FILE'))" 2>/dev/null; then
    log "Backup validated: valid JSON"
else
    log "WARNING: Backup may be corrupted (not valid JSON)"
fi

# Get file size before compression
ORIGINAL_SIZE=$(wc -c < "$BACKUP_FILE" | tr -d ' ')
log "Original size: ${ORIGINAL_SIZE} bytes"

# Compress backup
gzip "$BACKUP_FILE"
COMPRESSED_SIZE=$(wc -c < "${BACKUP_FILE}.gz" | tr -d ' ')
log "Compressed: ${BACKUP_FILE}.gz (${COMPRESSED_SIZE} bytes)"

# ----------------------------------------
# Clean old backups
# ----------------------------------------
DELETED_COUNT=$(find "$BACKUP_DIR" -name "dayplan_*.json.gz" -mtime +"$RETENTION_DAYS" -print -delete | wc -l | tr -d ' ')
if [ "$DELETED_COUNT" -gt 0 ]; then
    log "Cleaned $DELETED_COUNT backup(s) older than $RETENTION_DAYS days"
fi

# ----------------------------------------
# Summary
# ----------------------------------------
TOTAL_BACKUPS=$(find "$BACKUP_DIR" -name "dayplan_*.json.gz" | wc -l | tr -d ' ')
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
log "Backup complete. Total backups: $TOTAL_BACKUPS ($TOTAL_SIZE)"
