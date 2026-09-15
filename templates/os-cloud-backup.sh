#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

# Automatically find the name of the newest system snapshot
LATEST_SNAP=$(basename "$(ls -td "{{BACKUP_MOUNT}}/OS_Backup/"* 2>/dev/null | head -n 1)" || true)
if [[ -z "$LATEST_SNAP" || "$LATEST_SNAP" == "*" ]]; then
    echo "Error: No snapshots found in {{BACKUP_MOUNT}}/OS_Backup"
    read -p "Press Enter to close this window..."
    exit 1
fi
echo "Found latest snapshot: $LATEST_SNAP"

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -p "Press Enter to close this window..."; exit 1; }

ARCHIVE_PATH="{{BACKUP_MOUNT}}/Personal/Cloud_Archive.btrfs.zst"
trap 'rm -f "$ARCHIVE_PATH"' EXIT

# Package and compress the snapshot
echo "Compressing snapshot (showing raw data processed)..."
sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 >"$ARCHIVE_PATH"

# Sync to cloud storage
echo "Uploading to cloud storage..."
rclone copy "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P

echo "Success! Your OS clone is safe in the cloud."
read -p "Press Enter to close this window..."
