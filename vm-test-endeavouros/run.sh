#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — In-VM Test Runner
#
# Runs the automated comprehensive test suite inside an isolated Arch Linux
# QEMU virtual machine with BTRFS root and simulated secondary backup storage.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SYNC_CODE=false
SHOW_HELP=false

for arg in "$@"; do
    case "$arg" in
        --sync)
            SYNC_CODE=true
            ;;
        --help|-h)
            SHOW_HELP=true
            ;;
        *)
            echo "Unknown argument: $arg"
            SHOW_HELP=true
            ;;
    esac
done

if [[ "$SHOW_HELP" == true ]]; then
    echo "Usage: ./run.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --sync    Sync current repo code into the VM before executing tests"
    echo "  -h, --help Show this help message"
    echo ""
    echo "Default (no args): Directly boots the existing VM image and runs the test suite."
    exit 0
fi

cd "$SCRIPT_DIR"

if [[ ! -f "backup.qcow2" || ! -f "backup-drive.qcow2" ]]; then
    echo "Error: VM disk images (backup.qcow2 / backup-drive.qcow2) not found in $SCRIPT_DIR."
    exit 1
fi

OVMF_BIOS="/usr/share/edk2/x64/OVMF.4m.fd"
if [[ ! -f "$OVMF_BIOS" ]]; then
    # Fallback paths for OVMF
    for path in /usr/share/ovmf/x64/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF.fd; do
        if [[ -f "$path" ]]; then
            OVMF_BIOS="$path"
            break
        fi
    done
fi

if [[ ! -f "$OVMF_BIOS" ]]; then
    echo "Error: UEFI OVMF firmware not found. Please install edk2-ovmf (sudo pacman -S edk2-ovmf)."
    exit 1
fi

if [[ "$SYNC_CODE" == true ]]; then
    echo "=== Syncing latest repository code to VM image ==="
    mkdir -p "$SCRIPT_DIR/cidata/wizard-code"
    rsync -a --exclude 'vm-test*' --exclude '.git' "$REPO_DIR/" "$SCRIPT_DIR/cidata/wizard-code/"
    
    # Bump instance-id so cloud-init runs the update
    NEW_ID="update-$(date +%s)"
    sed -i "s/^instance-id:.*/instance-id: $NEW_ID/" "$SCRIPT_DIR/cidata/meta-data"

    genisoimage -output "$SCRIPT_DIR/cidata.iso" \
        -volid cidata -joliet -rock -allow-leading-dots \
        "$SCRIPT_DIR/cidata/meta-data" \
        "$SCRIPT_DIR/cidata/user-data" \
        "$SCRIPT_DIR/cidata/setup_btrfs.sh" \
        "$SCRIPT_DIR/cidata/run_vm_tests.sh" \
        "$SCRIPT_DIR/cidata/wizard-code" >/dev/null 2>&1

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
fi

echo "=== Booting Arch Linux BTRFS VM for Automated Tests ==="
nice -n 19 ionice -c 3 qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -nographic \
    -bios "$OVMF_BIOS" \
    -drive file=backup.qcow2,format=qcow2,if=virtio \
    -drive file=backup-drive.qcow2,format=qcow2,if=virtio \
    -net nic,model=virtio \
    -net user \
    -serial file:test_run.log

echo ""
echo "=== Test Results Summary ==="
if [[ -f "test_run.log" ]]; then
    grep -E "\[TEST|IN-VM TEST SUMMARY|SUCCESS|FAILURE" test_run.log || true
fi
