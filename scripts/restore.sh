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

# List of volumes to restore
VOLUMES=(
    "webclaw-docker_dna-data"
    "webclaw-docker_projects"
    "webclaw-docker_vibe-kanban-data"
    "webclaw-docker_code-server-data"
    "webclaw-docker_user-data"
    "webclaw-docker_openclaw-data"
    "webclaw-docker_chrome-data"
    "webclaw-docker_v2rayn-data"
    "webclaw-docker_gitconfig"
    "webclaw-docker_recordings"
    "webclaw-docker_webclaw-config"
    "webclaw-docker_ssh-data"
    "webclaw-docker_servers-data"
    "webclaw-docker_ai-studio-data"
    "webclaw-docker_skills-data"
    "webclaw-docker_obsidian-data"
)

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
TEMP_CONTAINER=$(docker create \
    -v webclaw-docker_dna-data:/restore/dna-data \
    -v webclaw-docker_projects:/restore/projects \
    -v webclaw-docker_vibe-kanban-data:/restore/vibe-kanban-data \
    -v webclaw-docker_code-server-data:/restore/code-server-data \
    -v webclaw-docker_user-data:/restore/user-data \
    -v webclaw-docker_openclaw-data:/restore/openclaw-data \
    -v webclaw-docker_chrome-data:/restore/chrome-data \
    -v webclaw-docker_v2rayn-data:/restore/v2rayn-data \
    -v webclaw-docker_gitconfig:/restore/gitconfig \
    -v webclaw-docker_recordings:/restore/recordings \
    -v webclaw-docker_webclaw-config:/restore/webclaw-config \
    -v webclaw-docker_ssh-data:/restore/ssh-data \
    -v webclaw-docker_servers-data:/restore/servers-data \
    -v webclaw-docker_ai-studio-data:/restore/ai-studio-data \
    -v webclaw-docker_skills-data:/restore/skills-data \
    -v webclaw-docker_obsidian-data:/restore/obsidian-data \
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
