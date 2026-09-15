#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -p "Press Enter to close this window..."; exit 1; }

for sub in {{DETECTED_SUBVOLUMES}}; do
    sub_safe="${sub//\//_}"
    # Automatically find the name of the newest snapshot for this subvolume
    LATEST_SNAP=$(basename "$(ls -td "{{BACKUP_MOUNT}}/OS_Backup/${sub_safe}."* 2>/dev/null | head -n 1)" || true)
    if [[ -z "$LATEST_SNAP" || "$LATEST_SNAP" == "*" ]]; then
        echo "Warning: No snapshots found for $sub_safe in {{BACKUP_MOUNT}}/OS_Backup"
        continue
    fi
    echo "Found latest snapshot for $sub: $LATEST_SNAP"

    ARCHIVE_PATH="{{BACKUP_MOUNT}}/Personal/${LATEST_SNAP}.btrfs.zst.age"
    
    # Package, compress, and encrypt the snapshot
    echo "Compressing and encrypting $LATEST_SNAP (showing raw data processed)..."
    sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 | age -r "{{AGE_PUBKEY}}" >"$ARCHIVE_PATH"
    
    # Sync to cloud storage
    echo "Uploading $LATEST_SNAP to cloud storage..."
    rclone copy "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P
    
    # Clean up local encrypted copy
    rm -f "$ARCHIVE_PATH"
done

echo "Success! Your OS clone is safe in the cloud."
read -p "Press Enter to close this window..."
