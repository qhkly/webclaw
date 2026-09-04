#!/bin/bash
#
# WebCode Backup Script
#
# Backs up all Docker volumes to a compressed tarball
# Usage: backup.sh [backup_name]
#   backup_name - optional, defaults to webclaw-YYYYMMDD-HHMMSS
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/volumes.sh
source "$SCRIPT_DIR/lib/volumes.sh"

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"
BACKUP_NAME="${1:-webclaw-$(date +%Y%m%d-%H%M%S)}"
BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
MAX_BACKUPS="${MAX_BACKUPS:-10}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[backup]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[backup]${NC} $1"
}

error() {
    echo -e "${RED}[backup]${NC} $1"
}

mapfile -t VOLUMES < <(webclaw_volumes)

# Create backup directory
mkdir -p "$BACKUP_DIR"

log "Starting backup: $BACKUP_NAME"
log "Backup directory: $BACKUP_DIR"

# Check if volumes exist
missing_volumes=()
for vol in "${VOLUMES[@]}"; do
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        missing_volumes+=("$vol")
    fi
done

if [ ${#missing_volumes[@]} -gt 0 ]; then
    warn "The following volumes do not exist and will be skipped:"
    for vol in "${missing_volumes[@]}"; do
        warn "  - $vol"
    done
fi

# Create temporary container for backup
log "Creating temporary backup container..."
volume_mounts=()
volume_prefix="$(webclaw_volume_prefix)"
for name in "${WEBCLAW_VOLUME_NAMES[@]}"; do
    volume_mounts+=( -v "${volume_prefix}${name}:/backup/${name}" )
done
TEMP_CONTAINER=$(docker create \
    "${volume_mounts[@]}" \
    -v "$BACKUP_DIR:/output" \
    ubuntu:22.04 \
    tar czf "/output/$(basename "$BACKUP_FILE")" -C /backup .)

# Start the container to create backup
log "Creating backup archive..."
docker start "$TEMP_CONTAINER" >/dev/null 2>&1

# Wait for backup to complete
if docker wait "$TEMP_CONTAINER" >/dev/null 2>&1; then
    log "Backup created successfully: $BACKUP_FILE"

    # Get backup size
    if [ -f "$BACKUP_FILE" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        log "Backup size: $BACKUP_SIZE"
    fi
else
    error "Backup creation failed"
    docker rm "$TEMP_CONTAINER" >/dev/null 2>&1
    exit 1
fi

# Clean up temporary container
docker rm "$TEMP_CONTAINER" >/dev/null 2>&1

# Create backup metadata
METADATA_FILE="$BACKUP_DIR/${BACKUP_NAME}.json"
cat > "$METADATA_FILE" << EOF
{
  "name": "$BACKUP_NAME",
  "created_at": "$(date -Iseconds)",
  "size": "$BACKUP_SIZE",
  "volumes": [$(printf '\n    "%s",' "${WEBCLAW_VOLUME_NAMES[@]}" | sed '$ s/,$//')
  ]
}
EOF

log "Backup metadata saved: $METADATA_FILE"

# Clean up old backups (keep only MAX_BACKUPS most recent)
log "Cleaning up old backups (keeping last $MAX_BACKUPS)..."
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/webclaw-*.tar.gz 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -1t "$BACKUP_DIR"/webclaw-*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | while read -r old_backup; do
        log "Removing old backup: $old_backup"
        rm -f "$old_backup"
        # Also remove metadata file if exists
        rm -f "${old_backup%.tar.gz}.json"
    done
fi

log "Backup completed successfully!"
log "Backup file: $BACKUP_FILE"
log "Metadata: $METADATA_FILE"

# List all available backups
log "Available backups:"
ls -lh "$BACKUP_DIR"/webclaw-*.tar.gz 2>/dev/null || echo "  No backups found"
