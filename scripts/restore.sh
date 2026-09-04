#!/bin/bash
#
# WebCode Restore Script
#
# Restores Docker volumes from a backup archive
# Usage: restore.sh <backup_name> [--force]
#   backup_name - name of the backup (without .tar.gz extension)
#   --force     - skip confirmation prompt
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/volumes.sh
source "$SCRIPT_DIR/lib/volumes.sh"

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/backups}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[restore]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[restore]${NC} $1"
}

error() {
    echo -e "${RED}[restore]${NC} $1"
}

info() {
    echo -e "${BLUE}[restore]${NC} $1"
}

# Check arguments
if [ $# -lt 1 ]; then
    error "Usage: $0 <backup_name> [--force]"
    echo ""
    info "Available backups:"
    ls -1 "$BACKUP_DIR"/webclaw-*.tar.gz 2>/dev/null | while read -r backup; do
        basename "$backup" .tar.gz
    done
    exit 1
fi

BACKUP_NAME="$1"
BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
METADATA_FILE="$BACKUP_DIR/${BACKUP_NAME}.json"
FORCE=false

if [ "$2" = "--force" ]; then
    FORCE=true
fi

# Check if backup exists
if [ ! -f "$BACKUP_FILE" ]; then
    error "Backup file not found: $BACKUP_FILE"
    echo ""
    info "Available backups:"
    ls -1 "$BACKUP_DIR"/webclaw-*.tar.gz 2>/dev/null | while read -r backup; do
        basename "$backup" .tar.gz
    done
    exit 1
fi

# Display backup metadata
if [ -f "$METADATA_FILE" ]; then
    log "Backup metadata:"
    cat "$METADATA_FILE" | grep -E '(name|created_at|size)' | sed 's/^/  /'
else
    warn "Metadata file not found, continuing anyway..."
fi

# Confirmation prompt
if [ "$FORCE" != true ]; then
    warn "This will REPLACE all current data with the backup!"
    warn "All changes since the backup will be LOST!"
    echo ""
    read -p "Are you sure you want to restore? Type 'yes' to confirm: " confirmation
    if [ "$confirmation" != "yes" ]; then
        log "Restore cancelled"
        exit 0
    fi
fi

log "Starting restore: $BACKUP_NAME"
log "Backup file: $BACKUP_FILE"

# Stop services to prevent data corruption during restore
log "Stopping services..."
supervisorctl stop code-server >/dev/null 2>&1 || true
supervisorctl stop vibe-kanban >/dev/null 2>&1 || true
supervisorctl stop openclaw >/dev/null 2>&1 || true
supervisorctl stop claudecodeui >/dev/null 2>&1 || true

mapfile -t VOLUMES < <(webclaw_volumes)

# Check if volumes exist
missing_volumes=()
for vol in "${VOLUMES[@]}"; do
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        missing_volumes+=("$vol")
    fi
done

if [ ${#missing_volumes[@]} -gt 0 ]; then
    warn "The following volumes do not exist and will be created:"
    for vol in "${missing_volumes[@]}"; do
        warn "  - $vol"
        docker volume create "$vol" >/dev/null 2>&1
    fi
fi

# Create temporary container for restore
log "Creating temporary restore container..."
volume_mounts=()
volume_prefix="$(webclaw_volume_prefix)"
for name in "${WEBCLAW_VOLUME_NAMES[@]}"; do
    volume_mounts+=( -v "${volume_prefix}${name}:/restore/${name}" )
done
TEMP_CONTAINER=$(docker create \
    "${volume_mounts[@]}" \
    -v "$BACKUP_DIR:/backup" \
    ubuntu:22.04 \
    tar xzf "/backup/$(basename "$BACKUP_FILE")" -C /restore)

# Start the container to restore
log "Restoring from backup..."
docker start "$TEMP_CONTAINER" >/dev/null 2>&1

# Wait for restore to complete
if docker wait "$TEMP_CONTAINER" >/dev/null 2>&1; then
    log "Restore completed successfully"
else
    error "Restore failed"
    docker rm "$TEMP_CONTAINER" >/dev/null 2>&1
    exit 1
fi

# Clean up temporary container
docker rm "$TEMP_CONTAINER" >/dev/null 2>&1

# Restart services
log "Restarting services..."
supervisorctl start code-server >/dev/null 2>&1 || true
supervisorctl start vibe-kanban >/dev/null 2>&1 || true
supervisorctl start openclaw >/dev/null 2>&1 || true
supervisorctl start claudecodeui >/dev/null 2>&1 || true

log "Restore completed successfully!"
log "Data restored from: $BACKUP_FILE"

# Display restore summary
if [ -f "$METADATA_FILE" ]; then
    info "Restore summary:"
    echo "  Backup name: $BACKUP_NAME"
    echo "  Restored at: $(date -Iseconds)"
fi
