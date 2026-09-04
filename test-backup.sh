#!/bin/bash
#
# Test backup and restore functionality
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/volumes.sh
source "$SCRIPT_DIR/scripts/lib/volumes.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[test]${NC} $1"
}

error() {
    echo -e "${RED}[test]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[test]${NC} $1"
}

log "Test 0: Checking backup volume manifest..."
compose_volumes="$(docker compose config --volumes | sort)"
manifest_volumes="$(printf '%s\n' "${WEBCLAW_VOLUME_NAMES[@]}" | sort)"
if [ "$compose_volumes" != "$manifest_volumes" ]; then
    error "Backup volume manifest differs from docker-compose.yml"
    diff -u <(printf '%s\n' "$compose_volumes") <(printf '%s\n' "$manifest_volumes") || true
    exit 1
fi
log "✓ Backup volume manifest matches docker-compose.yml"

# Check if container is running
if ! docker ps | grep -q webcode; then
    error "Container 'webcode' is not running. Please start it first:"
    echo "  docker compose up -d"
    exit 1
fi

log "Container 'webcode' is running"

# Test 1: Check if scripts are executable
log "Test 1: Checking if backup scripts are executable..."
if docker exec webcode test -x /opt/backup.sh && docker exec webcode test -x /opt/restore.sh; then
    log "✓ Scripts are executable"
else
    error "✗ Scripts are not executable"
    exit 1
fi

# Test 2: Check if backup directory exists
log "Test 2: Checking if backup directory exists..."
if docker exec webcode test -d /home/ubuntu/backups; then
    log "✓ Backup directory exists"
else
    error "✗ Backup directory does not exist"
    exit 1
fi

# Test 3: Create a test backup
log "Test 3: Creating a test backup..."
BACKUP_NAME="test-backup-$(date +%Y%m%d-%H%M%S)"
if docker exec webcode bash -c "BACKUP_DIR=/home/ubuntu/backups bash /opt/backup.sh $BACKUP_NAME" > /tmp/backup-test.log 2>&1; then
    log "✓ Backup created successfully"
else
    error "✗ Backup creation failed"
    cat /tmp/backup-test.log
    exit 1
fi

# Test 4: Check if backup files exist
log "Test 4: Checking if backup files exist..."
if docker exec webcode test -f "/home/ubuntu/backups/${BACKUP_NAME}.tar.gz" && \
   docker exec webcode test -f "/home/ubuntu/backups/${BACKUP_NAME}.json"; then
    log "✓ Backup files exist"

    # Show backup size
    BACKUP_SIZE=$(docker exec webcode stat -c%s "/home/ubuntu/backups/${BACKUP_NAME}.tar.gz" 2>/dev/null || echo "0")
    log "Backup size: $BACKUP_SIZE bytes"
else
    error "✗ Backup files do not exist"
    exit 1
fi

# Test 5: Verify backup metadata
log "Test 5: Verifying backup metadata..."
METADATA=$(docker exec webcode cat "/home/ubuntu/backups/${BACKUP_NAME}.json")
if echo "$METADATA" | grep -q "name" && echo "$METADATA" | grep -q "created_at"; then
    log "✓ Backup metadata is valid"
else
    error "✗ Backup metadata is invalid"
    exit 1
fi

# Test 6: Check API endpoints
log "Test 6: Testing API endpoints..."

# Test list API
if curl -s http://localhost:20000/api/backup/list | grep -q "name"; then
    log "✓ GET /api/backup/list works"
else
    warn "✗ GET /api/backup/list failed (may need to check authentication)"
fi

# Test 7: Clean up test backup
log "Test 7: Cleaning up test backup..."
docker exec webcode rm -f "/home/ubuntu/backups/${BACKUP_NAME}.tar.gz" "/home/ubuntu/backups/${BACKUP_NAME}.json"
log "✓ Test backup cleaned up"

log ""
log "All tests passed! ✓"
log ""
log "You can now use the backup system:"
log "  - Web UI: http://localhost:20000 (click '备份' tab)"
log "  - CLI: docker exec -it webcode bash /opt/backup.sh"
log ""
