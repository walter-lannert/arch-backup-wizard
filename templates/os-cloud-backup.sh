#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

# Automatically find the name of the newest system snapshot
LATEST_SNAP=$(ls -t "{{BACKUP_MOUNT}}/OS_Backup" 2>/dev/null | head -n 1 || true)
if [[ -z "$LATEST_SNAP" ]]; then
    echo "Error: No snapshots found in {{BACKUP_MOUNT}}/OS_Backup"
    read -p "Press Enter to close this window..."
    exit 1
fi
echo "Found latest snapshot: $LATEST_SNAP"

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -p "Press Enter to close this window..."; exit 1; }

# Package and compress the snapshot
echo "Compressing snapshot (showing raw data processed)..."
sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 >"{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst"

# Sync to cloud storage
echo "Uploading to cloud storage..."
rclone copy "{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P

# Clean up the local file
echo "Cleaning up local archive..."
rm "{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst"

echo "Success! Your OS clone is safe in the cloud."
read -p "Press Enter to close this window..."
