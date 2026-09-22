#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

cleanup_files=()
trap '[[ ${#cleanup_files[@]} -gt 0 ]] && sudo rm -f "${cleanup_files[@]}" 2>/dev/null || true' EXIT

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -p "Press Enter to close this window..."; exit 1; }

while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    sub_safe="${sub//\//_}"
    # Automatically find the name of the newest snapshot for this subvolume (relying on btrbk's deterministic timestamp naming)
    LATEST_SNAP=$(basename "$(ls -d "{{BACKUP_MOUNT}}/OS_Backup/${sub_safe}."20[0-9][0-9]* 2>/dev/null | sort -r | head -n 1)" || true)
    if [[ -z "$LATEST_SNAP" || "$LATEST_SNAP" == "*" ]]; then
        echo "Warning: No snapshots found for $sub_safe in {{BACKUP_MOUNT}}/OS_Backup"
        continue
    fi
    echo "Found latest snapshot for $sub: $LATEST_SNAP"

    ARCHIVE_PATH="{{BACKUP_MOUNT}}/OS_Backup/${LATEST_SNAP}.btrfs.zst.age"
    cleanup_files+=("$ARCHIVE_PATH")

    # Package, compress, and encrypt the snapshot
    echo "Compressing and encrypting $LATEST_SNAP (showing raw data processed)..."
    sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 | age -r "{{AGE_PUBKEY}}" | sudo tee "$ARCHIVE_PATH" > /dev/null

    # Sync to cloud storage
    echo "Uploading $LATEST_SNAP to cloud storage..."
    rclone copy "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P

    # Clean up local encrypted copy
    sudo rm -f "$ARCHIVE_PATH"
done <<< "{{DETECTED_SUBVOLUMES}}"

echo "Success! Your OS clone is safe in the cloud."
read -p "Press Enter to close this window..."
