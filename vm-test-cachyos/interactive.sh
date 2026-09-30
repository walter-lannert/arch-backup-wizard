#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — Interactive In-VM Manual Session
#
# Launches an interactive CachyOS terminal console with real dialog TUI.
# By default uses -snapshot to avoid modifying the base image.
# Pass --persist to save manual changes directly to the disk images.
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

PERSIST=false
for arg in "$@"; do
    case "$arg" in
        --persist)
            PERSIST=true
            ;;
        -h|--help)
            echo "Usage: ./interactive.sh [--persist]"
            echo ""
            echo "  --persist   Save changes to base disk images (default: ephemeral -snapshot)"
            exit 0
            ;;
    esac
done

SNAPSHOT_OPT=("-snapshot")
if [[ "$PERSIST" == true ]]; then
    SNAPSHOT_OPT=()
    echo ">>> Running in PERSISTENT mode: changes will be saved to disk images."
else
    echo ">>> Running in SNAPSHOT mode (-snapshot): changes will NOT modify base images."
fi

echo "================================================================================"
echo "          ARCH BACKUP WIZARD — INTERACTIVE VM SESSION"
echo "================================================================================"
echo ">>> VM serial console is attached directly to your terminal."
echo ">>> You are logged in automatically as 'root' on ttyS0."
echo ">>> To test as non-root user 'arch' with sudo:"
echo "      su - arch"
echo "      cd /home/arch/arch-backup-wizard"
echo "      sudo ./wizard.sh"
echo ">>> To test directly as root:"
echo "      cd /root/arch-backup-wizard"
echo "      ./wizard.sh"
echo ">>> When finished, type 'poweroff' (or press Ctrl-A then x) to exit QEMU."
echo "================================================================================"
echo ""

nice -n 19 ionice -c 3 qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -nographic \
    -bios "$OVMF_BIOS" \
    "${SNAPSHOT_OPT[@]}" \
    -drive file=backup.qcow2,format=qcow2,if=virtio \
    -drive file=backup-drive.qcow2,format=qcow2,if=virtio \
    -net nic,model=virtio \
    -net user \
    -serial mon:stdio
