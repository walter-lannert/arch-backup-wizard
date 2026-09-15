#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

# Automatically find the name of the newest system snapshot for the root subvolume
LATEST_SNAP=$(basename "$(ls -td "{{BACKUP_MOUNT}}/OS_Backup/{{DETECTED_ROOT_SUBVOL_STR}}"* 2>/dev/null | head -n 1)" || true)
if [[ -z "$LATEST_SNAP" || "$LATEST_SNAP" == "*" ]]; then
    echo "Error: No snapshots found in {{BACKUP_MOUNT}}/OS_Backup"
    read -p "Press Enter to close this window..."
    exit 1
fi
echo "Found latest snapshot: $LATEST_SNAP"

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -p "Press Enter to close this window..."; exit 1; }

ARCHIVE_PATH="{{BACKUP_MOUNT}}/Personal/Cloud_Archive.btrfs.zst.age"
trap 'rm -f "$ARCHIVE_PATH"' EXIT

# Package, compress, and encrypt the snapshot
echo "Compressing and encrypting snapshot (showing raw data processed)..."
sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 | age -r "{{AGE_PUBKEY}}" >"$ARCHIVE_PATH"

# Sync to cloud storage
echo "Uploading to cloud storage..."
rclone copy "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P

echo "Success! Your OS clone is safe in the cloud."
read -p "Press Enter to close this window..."
