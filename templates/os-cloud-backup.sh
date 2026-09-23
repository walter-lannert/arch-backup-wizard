#!/bin/bash
set -euo pipefail

echo "Starting Bare-Metal OS Cloud Backup..."

cleanup_files=()
trap '[[ ${#cleanup_files[@]} -gt 0 ]] && sudo rm -f "${cleanup_files[@]}" 2>/dev/null || true' EXIT INT TERM HUP
trap 'echo -e "\n\033[0;31m[ERROR] Cloud backup encountered an unrecoverable failure. See log above.\033[0m"; read -r -p "Press Enter to close this window...";' ERR

# Preemptively clean up any orphaned archives from previously killed runs
sudo rm -f "{{BACKUP_MOUNT}}/OS_Backup/"*.btrfs.zst.age 2>/dev/null || true

# Authenticate sudo cleanly first so the password prompt isn't overwritten by pv
sudo -v || { echo "Error: sudo authentication failed."; read -r -p "Press Enter to close this window..."; exit 1; }

uploaded_count=0
while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    sub_safe="${sub//\//_}"
    # Automatically find the name of the newest snapshot for this subvolume (relying on btrbk's deterministic timestamp naming)
    LATEST_SNAP_PATH=$(find "{{BACKUP_MOUNT}}/OS_Backup" -maxdepth 1 -mindepth 1 -type d -name "${sub_safe}.20*" 2>/dev/null | sort -r | head -n 1 || true)
    if [[ -z "$LATEST_SNAP_PATH" || ! -d "$LATEST_SNAP_PATH" ]]; then
        echo "Warning: No snapshots found for $sub_safe in {{BACKUP_MOUNT}}/OS_Backup"
        continue
    fi
    LATEST_SNAP=$(basename "$LATEST_SNAP_PATH")
    echo "Found latest snapshot for $sub: $LATEST_SNAP"

    ARCHIVE_PATH="{{BACKUP_MOUNT}}/OS_Backup/${LATEST_SNAP}.btrfs.zst.age"
    cleanup_files+=("$ARCHIVE_PATH")

    # Package, compress, and encrypt the snapshot
    echo "Compressing and encrypting $LATEST_SNAP (showing raw data processed)..."
    sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | pv -trab | zstd -T0 | age -r "{{AGE_PUBKEY}}" | sudo tee "$ARCHIVE_PATH" > /dev/null
    sudo chmod 644 "$ARCHIVE_PATH"

    # Sync to cloud storage
    echo "Uploading $LATEST_SNAP to cloud storage..."
    rclone copyto "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}/${LATEST_SNAP}.btrfs.zst.age" -P

    # Clean up local encrypted copy
    sudo rm -f "$ARCHIVE_PATH"
    cleanup_files=()
    ((uploaded_count++))
done <<< "{{DETECTED_SUBVOLUMES}}"

if [[ $uploaded_count -eq 0 ]]; then
    echo -e "\n\033[0;31m[ERROR] No snapshots were found in {{BACKUP_MOUNT}}/OS_Backup. Cloud backup failed.\033[0m"
    echo "Run a local btrbk backup first (sudo btrbk run) before syncing to the cloud."
    read -r -p "Press Enter to close this window..."
    exit 1
fi

echo "Success! Your OS clone is safe in the cloud."
read -r -p "Press Enter to close this window..."
