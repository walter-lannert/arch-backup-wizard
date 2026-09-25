#!/bin/bash
set -euo pipefail

LOCK_FILE="/run/lock/os-cloud-backup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Error: another cloud-backup instance is already running."
    read -r -p "Press Enter to close this window..."
    exit 1
fi

echo "Starting Bare-Metal OS Cloud Backup..."

cleanup_files=()
SUDO_KEEP_PID=""
trap '[[ -n "${SUDO_KEEP_PID:-}" ]] && kill "$SUDO_KEEP_PID" 2>/dev/null || true; [[ ${#cleanup_files[@]} -gt 0 ]] && sudo -n rm -f "${cleanup_files[@]}" 2>/dev/null || true' EXIT INT TERM HUP
trap 'echo -e "\n\033[0;31m[ERROR] Cloud backup encountered an unrecoverable failure. See log above.\033[0m"; read -r -p "Press Enter to close this window...";' ERR

# Authenticate sudo cleanly and spawn background keep-alive for long uploads
sudo -v || { echo "Error: sudo authentication failed."; read -r -p "Press Enter to close this window..."; exit 1; }
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_PID=$!

# Preemptively clean up any orphaned archives from previously killed runs
sudo rm -f "{{BACKUP_MOUNT}}/OS_Backup/"*.btrfs.zst.age 2>/dev/null || true

uploaded_count=0
while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    sub_safe="${sub//\//_}"
    sub_escaped="${sub_safe//[\*\?\[\]]/\\&}"
    # Automatically find the name of the newest snapshot for this subvolume (relying on btrbk's deterministic timestamp naming)
    LATEST_SNAP_PATH=$(sudo find "{{BACKUP_MOUNT}}/OS_Backup" -maxdepth 1 -mindepth 1 -type d -name "${sub_escaped}.20*" 2>/dev/null | sort -r | head -n 1 || true)
    if [[ -z "$LATEST_SNAP_PATH" ]]; then
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
    rclone copyto "$ARCHIVE_PATH" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}/${LATEST_SNAP}.btrfs.zst.age" -P --contimeout 30s --timeout 10m

    # Verify upload integrity before deleting local copy
    local_size=$(sudo stat -c%s "$ARCHIVE_PATH")
    remote_size=$(rclone lsl "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}/${LATEST_SNAP}.btrfs.zst.age" 2>/dev/null | awk '{print $1}')
    if [[ -z "$remote_size" || "$remote_size" -ne "$local_size" ]]; then
        echo "Error: upload size mismatch for $LATEST_SNAP (local=$local_size remote=${remote_size:-unknown})."
        exit 1
    fi

    # Clean up local encrypted copy
    sudo rm -f "$ARCHIVE_PATH"
    uploaded_count=$((uploaded_count + 1))
done <<< "{{DETECTED_SUBVOLUMES}}"

if [[ $uploaded_count -eq 0 ]]; then
    echo -e "\n\033[0;31m[ERROR] No snapshots were found in {{BACKUP_MOUNT}}/OS_Backup. Cloud backup failed.\033[0m"
    echo "Run a local btrbk backup first (sudo btrbk run) before syncing to the cloud."
    read -r -p "Press Enter to close this window..."
    exit 1
fi

_year=$(date +%Y)
_month=$(date +%m)
_day=$(date +%-d)
_period="1"
if [ "$_day" -ge 15 ]; then
    _period="2"
fi
echo "${_year}-${_month}-P${_period}" > "{{DETECTED_HOME}}/.last_cloud_run"

echo "Success! Your OS clone is safe in the cloud."
read -r -p "Press Enter to close this window..."
