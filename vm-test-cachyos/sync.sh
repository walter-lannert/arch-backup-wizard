#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — VM Code Sync
#
# Synchronizes the current workspace code into the CachyOS VM disk image.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"

if [[ ! -f "backup.qcow2" || ! -f "Arch-Linux-x86_64-cloudimg.qcow2" ]]; then
    echo "Error: Required disk images not found in $SCRIPT_DIR."
    exit 1
fi

echo "=== Syncing latest repository code to VM image ==="
mkdir -p "$SCRIPT_DIR/cidata/wizard-code"
rsync -a --exclude 'vm-test*' --exclude '.git' "$REPO_DIR/" "$SCRIPT_DIR/cidata/wizard-code/"

# Bump instance-id so cloud-init runs the update
NEW_ID="update-$(date +%s)"
sed -i "s/^instance-id:.*/instance-id: $NEW_ID/" "$SCRIPT_DIR/cidata/meta-data"

local_cidata_files=(
    "$SCRIPT_DIR/cidata/meta-data"
    "$SCRIPT_DIR/cidata/user-data"
    "$SCRIPT_DIR/cidata/setup_btrfs.sh"
    "$SCRIPT_DIR/cidata/run_vm_tests.sh"
    "$SCRIPT_DIR/cidata/wizard-code"
)

genisoimage -output "$SCRIPT_DIR/cidata.iso" \
    -volid cidata -joliet -rock -allow-leading-dots \
    "${local_cidata_files[@]}" >/dev/null 2>&1

echo "=== Updating VM disk via cloud-init bootstrap ==="
nice -n 19 ionice -c 3 qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -nographic \
    -drive file=Arch-Linux-x86_64-cloudimg.qcow2,format=qcow2,if=virtio \
    -drive file=backup.qcow2,format=qcow2,if=virtio \
    -cdrom cidata.iso \
    -net nic,model=virtio \
    -net user \
    -serial file:update.log

rm -rf "$SCRIPT_DIR/cidata/wizard-code" "$SCRIPT_DIR/cidata.iso" "$SCRIPT_DIR/update.log"
echo "=== Sync completed successfully ==="
