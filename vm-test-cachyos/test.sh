#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — Automated In-VM Test Runner
#
# Executes the 30-stage automated test suite inside an isolated CachyOS VM.
# Runs with QEMU -snapshot to ensure the base disk images are never modified.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f "backup.qcow2" || ! -f "backup-drive.qcow2" ]]; then
    echo "Error: VM disk images (backup.qcow2 / backup-drive.qcow2) not found in $SCRIPT_DIR."
    exit 1
fi

OVMF_BIOS="/usr/share/edk2/x64/OVMF.4m.fd"
if [[ ! -f "$OVMF_BIOS" ]]; then
    for path in /usr/share/ovmf/x64/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF.fd; do
        if [[ -f "$path" ]]; then
            OVMF_BIOS="$path"
            break
        fi
    done
fi

if [[ ! -f "$OVMF_BIOS" ]]; then
    echo "Error: UEFI OVMF firmware not found. Please install edk2-ovmf."
    exit 1
fi

# Create ephemeral test trigger ISO
TRIGGER_ISO="$(mktemp /tmp/abw-trigger.XXXXXX.iso)"
genisoimage -output "$TRIGGER_ISO" -volid TEST_AUTOMATED /dev/null >/dev/null 2>&1
trap 'rm -f "$TRIGGER_ISO" 2>/dev/null' EXIT

echo "=== Booting CachyOS BTRFS VM for Automated Tests (-snapshot) ==="
rm -f test_run.log

nice -n 19 ionice -c 3 qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -nographic \
    -bios "$OVMF_BIOS" \
    -snapshot \
    -drive file=backup.qcow2,format=qcow2,if=virtio \
    -drive file=backup-drive.qcow2,format=qcow2,if=virtio \
    -cdrom "$TRIGGER_ISO" \
    -net nic,model=virtio \
    -net user \
    -serial file:test_run.log

echo ""
echo "=== In-VM Test Results Summary ==="
if [[ -f "test_run.log" ]]; then
    grep -E "\[TEST|IN-VM TEST SUMMARY|SUCCESS|FAILURE" test_run.log || true
    if grep -q "FAILURE:" test_run.log; then
        echo "Error: VM test suite reported failures."
        exit 1
    elif ! grep -q "SUCCESS: ALL IN-VM TESTS PASSED AS INTENDED!" test_run.log; then
        echo "Error: VM test suite did not complete successfully (crashed or hung)."
        exit 1
    fi
else
    echo "Error: test_run.log was not generated."
    exit 1
fi
