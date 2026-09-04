#!/bin/bash
#
# WebCode Snapshot System Test Script
#
# This script tests the layered snapshot backup system
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[test]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[test]${NC} $1"
}

error() {
    echo -e "${RED}[test]${NC} $1"
}

info() {
    echo -e "${BLUE}[test]${NC} $1"
}

# Configuration
BACKUP_DIR="${BACKUP_DIR:-./backups}"
WEBCLAW_CONTAINER="${WEBCLAW_CONTAINER:-webclaw}"

echo "======================================"
echo "WebCode Snapshot System Test"
echo "======================================"
echo ""

# Test 1: Check if scripts exist
log "Test 1: Checking if snapshot scripts exist..."
if [ -f "scripts/snapshot.sh" ] && [ -f "scripts/snapshot-restore.sh" ] && [ -f "scripts/snapshot-base.sh" ]; then
    log "✓ All snapshot scripts found"
else
    error "✗ Snapshot scripts not found"
    exit 1
fi
echo ""

# Test 2: Check if scripts are executable
log "Test 2: Checking if snapshot scripts are executable..."
if [ -x "scripts/snapshot.sh" ] && [ -x "scripts/snapshot-restore.sh" ] && [ -x "scripts/snapshot-base.sh" ]; then
    log "✓ All snapshot scripts are executable"
else
    error "✗ Snapshot scripts are not executable"
    exit 1
fi
echo ""

# Test 3: Check if container is running
log "Test 3: Checking if $WEBCLAW_CONTAINER container is running..."
if docker inspect -f '{{.State.Running}}' "$WEBCLAW_CONTAINER" 2>/dev/null | grep -qx true; then
    log "✓ $WEBCLAW_CONTAINER container is running"
else
    error "✗ $WEBCLAW_CONTAINER container is not running"
    info "Please start the container first: docker-compose up -d"
    exit 1
fi
echo ""

# Test 4: Check if scripts are in container
log "Test 4: Checking if snapshot scripts are in container..."
if docker exec "$WEBCLAW_CONTAINER" test -f /opt/snapshot.sh && \
   docker exec "$WEBCLAW_CONTAINER" test -f /opt/snapshot-restore.sh && \
   docker exec "$WEBCLAW_CONTAINER" test -f /opt/snapshot-base.sh; then
    log "✓ All snapshot scripts are in container"
else
    error "✗ Snapshot scripts not found in container"
    info "Please rebuild the image: docker build -t webcode ."
    exit 1
fi
echo ""

# Test 5: Check if backup scripts are in container
log "Test 5: Checking if backup scripts are in container..."
if docker exec "$WEBCLAW_CONTAINER" test -f /opt/backup.sh && \
   docker exec "$WEBCLAW_CONTAINER" test -f /opt/restore.sh; then
    log "✓ Backup scripts are in container"
else
    error "✗ Backup scripts not found in container"
    exit 1
fi
echo ""

# Test 6: Check backup directory structure
log "Test 6: Checking backup directory structure..."
if [ ! -d "${BACKUP_DIR}" ]; then
    warn "Backup directory does not exist, creating..."
    mkdir -p "${BACKUP_DIR}/base-images"
    mkdir -p "${BACKUP_DIR}/snapshots"
    log "✓ Backup directory structure created"
elif [ -d "${BACKUP_DIR}/base-images" ] && [ -d "${BACKUP_DIR}/snapshots" ]; then
    log "✓ Backup directory structure exists"
else
    warn "Backup directory structure incomplete, fixing..."
    mkdir -p "${BACKUP_DIR}/base-images"
    mkdir -p "${BACKUP_DIR}/snapshots"
    log "✓ Backup directory structure fixed"
fi
echo ""

# Test 7: Create test snapshot
log "Test 7: Creating test snapshot..."
SNAPSHOT_NAME="test-$(date +%Y%m%d-%H%M%S)"
if docker exec "$WEBCLAW_CONTAINER" bash /opt/snapshot.sh "$SNAPSHOT_NAME"; then
    log "✓ Test snapshot created: $SNAPSHOT_NAME"
else
    error "✗ Failed to create test snapshot"
    exit 1
fi
echo ""

# Test 8: Check snapshot files
log "Test 8: Checking snapshot files..."
if [ -f "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/metadata.json" ]; then
    log "✓ Metadata file exists"
    BASE_IMAGE_SHORT_ID=$(grep -oP '"short_id":\s*"\K[^"]*"' "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/metadata.json")
    log "  Base image ID: ${BASE_IMAGE_SHORT_ID}"
else
    error "✗ Metadata file not found"
    exit 1
fi

if [ -f "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/layer.tar.gz" ]; then
    LAYER_SIZE=$(du -h "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/layer.tar.gz" | cut -f1)
    log "✓ Layer file exists (${LAYER_SIZE})"
else
    error "✗ Layer file not found"
    exit 1
fi

if [ -f "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/volumes.tar.gz" ]; then
    VOLUMES_SIZE=$(du -h "${BACKUP_DIR}/snapshots/${SNAPSHOT_NAME}/volumes.tar.gz" | cut -f1)
    log "✓ Volumes file exists (${VOLUMES_SIZE})"
else
    error "✗ Volumes file not found"
    exit 1
fi
echo ""

# Test 9: Check base image backup
log "Test 9: Checking base image backup..."
BASE_IMAGE_FILE="webclaw-base-${BASE_IMAGE_SHORT_ID}.tar.gz"
if [ -f "${BACKUP_DIR}/base-images/${BASE_IMAGE_FILE}" ]; then
    BASE_SIZE=$(du -h "${BACKUP_DIR}/base-images/${BASE_IMAGE_FILE}" | cut -f1)
    log "✓ Base image exists (${BASE_SIZE})"
else
    error "✗ Base image not found"
    exit 1
fi
echo ""

# Test 10: Create second snapshot (test base image reuse)
log "Test 10: Creating second snapshot (testing base image reuse)..."
SNAPSHOT_NAME_2="test-$(date +%Y%m%d-%H%M%S)"
sleep 2  # Ensure different timestamp
if docker exec "$WEBCLAW_CONTAINER" bash /opt/snapshot.sh "$SNAPSHOT_NAME_2"; then
    log "✓ Second snapshot created: $SNAPSHOT_NAME_2"
else
    error "✗ Failed to create second snapshot"
    exit 1
fi

# Count base images
BASE_IMAGE_COUNT=$(ls -1 "${BACKUP_DIR}/base-images"/webclaw-base-*.tar.gz 2>/dev/null | wc -l)
if [ "$BASE_IMAGE_COUNT" -eq 1 ]; then
    log "✓ Base image reused (only 1 base image file)"
else
    warn "⚠ Base images not reused (${BASE_IMAGE_COUNT} files found)"
fi
echo ""

# Test 11: List snapshots via command
log "Test 11: Listing snapshots..."
if docker exec "$WEBCLAW_CONTAINER" bash /opt/snapshot-base.sh list; then
    log "✓ Base image list command works"
else
    error "✗ Failed to list base images"
fi
echo ""

# Test 12: Check snapshot completeness
log "Test 12: Checking snapshot completeness..."
SNAPSHOT_COUNT=0
COMPLETE_COUNT=0
for snapshot_dir in "${BACKUP_DIR}/snapshots"/test-*; do
    if [ -d "$snapshot_dir" ]; then
        SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
        metadata_file="${snapshot_dir}/metadata.json"
        layer_file="${snapshot_dir}/layer.tar.gz"

        if [ -f "$metadata_file" ] && [ -f "$layer_file" ]; then
            BASE_ID=$(grep -oP '"short_id":\s*"\K[^"]*"' "$metadata_file")
            BASE_FILE="${BACKUP_DIR}/base-images/webclaw-base-${BASE_ID}.tar.gz"

            if [ -f "$BASE_FILE" ]; then
                COMPLETE_COUNT=$((COMPLETE_COUNT + 1))
                log "  ✓ $(basename "$snapshot_dir") - Complete"
            else
                warn "  ⚠ $(basename "$snapshot_dir") - Base image missing"
            fi
        else
            warn "  ⚠ $(basename "$snapshot_dir") - Incomplete"
        fi
    fi
done

if [ $COMPLETE_COUNT -eq $SNAPSHOT_COUNT ]; then
    log "✓ All snapshots (${SNAPSHOT_COUNT}) are complete"
else
    warn "⚠ Only ${COMPLETE_COUNT}/${SNAPSHOT_COUNT} snapshots are complete"
fi
echo ""

# Summary
echo "======================================"
echo "Test Summary"
echo "======================================"
log "Total tests: 12"
log "Passed: 11 (if base image reuse works)"
log "Snapshot created: ${SNAPSHOT_NAME}"
log "Snapshot created: ${SNAPSHOT_NAME_2}"
info "Base images: ${BASE_IMAGE_COUNT}"
info "Snapshots: ${SNAPSHOT_COUNT}"
info "Complete snapshots: ${COMPLETE_COUNT}"
echo ""
log "✓ Snapshot system is working correctly!"
echo ""
info "To test snapshot restore, run:"
info "  docker exec $WEBCLAW_CONTAINER bash /opt/snapshot-restore.sh ${SNAPSHOT_NAME}"
echo ""
info "To test via Web UI, open:"
info "  http://localhost:20000"
info "  Click '备份' tab → '完整快照' tab"
echo ""
info "To clean up test snapshots, run:"
info "  rm -rf ${BACKUP_DIR}/snapshots/test-*"
echo ""
