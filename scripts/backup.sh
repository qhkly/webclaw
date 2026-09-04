#!/bin/bash
#
# WebCode Backup Script
#
# Backs up all Docker volumes to a compressed tarball
# Usage: backup.sh [backup_name]
#   backup_name - optional, defaults to webclaw-YYYYMMDD-HHMMSS
#

set -e

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

# List of volumes to backup (from docker-compose.yml)
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
TEMP_CONTAINER=$(docker create \
    -v webclaw-docker_dna-data:/backup/dna-data \
    -v webclaw-docker_projects:/backup/projects \
    -v webclaw-docker_vibe-kanban-data:/backup/vibe-kanban-data \
    -v webclaw-docker_code-server-data:/backup/code-server-data \
    -v webclaw-docker_user-data:/backup/user-data \
    -v webclaw-docker_openclaw-data:/backup/openclaw-data \
    -v webclaw-docker_chrome-data:/backup/chrome-data \
    -v webclaw-docker_v2rayn-data:/backup/v2rayn-data \
    -v webclaw-docker_gitconfig:/backup/gitconfig \
    -v webclaw-docker_recordings:/backup/recordings \
    -v webclaw-docker_webclaw-config:/backup/webclaw-config \
    -v webclaw-docker_ssh-data:/backup/ssh-data \
    -v webclaw-docker_servers-data:/backup/servers-data \
    -v webclaw-docker_ai-studio-data:/backup/ai-studio-data \
    -v webclaw-docker_skills-data:/backup/skills-data \
    -v webclaw-docker_obsidian-data:/backup/obsidian-data \
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
  "volumes": [
    "dna-data",
    "projects",
    "vibe-kanban-data",
    "code-server-data",
    "user-data",
    "openclaw-data",
    "chrome-data",
    "v2rayn-data",
    "gitconfig",
    "recordings",
    "webclaw-config",
    "ssh-data",
    "servers-data",
    "ai-studio-data",
    "skills-data",
    "obsidian-data"
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
