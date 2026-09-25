#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_helper.bash
source "$SCRIPT_DIR/test_helper.bash"
source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/runbooks.sh"

ui_msgbox() { return 0; }
ui_yesno() { return 0; }

test_manjaro_grub() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export SETTINGS_FILE="$TEST_TEMP_DIR/settings.env"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="manjarouser"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="manjaro-root-3333"
    export DETECTED_EFI_UUID="manjaro-efi-4444"
    export DETECTED_BOOTLOADER="grub"
    export DETECTED_HOSTNAME="manjaro-desktop"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="standard"
    export DETECTED_DISTRO="Manjaro"
    export DETECTED_SUBVOLUMES="@
@home"
    export DETECTED_SUBVOL_MOUNTS="/home:@home"
    export DETECTED_EFI_MOUNT="/boot/efi"
    export BACKUP_UUID="manjaro-backup-5555"

    export CLOUD_REMOTE="drive:"
    export CLOUD_OS_DIR="Manjaro_OS"
    export CLOUD_PIKA_DIR="Manjaro_Pika"
    export CLOUD_AGE_KEY="/root/cloud_os.key"

    export WIZARD_DIR="$REPO_DIR"
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    export SELECTED_LAYERS=("1" "2" "3" "4" "5")
    export LAYER4_ENCRYPT="true"

    mock_cmd pacman 'echo "linux linux-headers"'
    mock_cmd hostname 'echo manjaro-desktop'
    mock_cmd chown 'exit 0'
    mock_cmd awk 'exit 0'

    save_settings
    generate_runbooks

    local rb1="$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt"
    local rb2="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"
    local rb3="$BACKUP_MOUNT/Cloud_Recovery_Runbook.txt"

    assert_file_exists "$rb1" "Layer 1 runbook should exist"
    assert_file_exists "$rb2" "Layer 2 runbook should exist"
    assert_file_exists "$rb3" "Layer 4 cloud runbook should exist"

    local c2 c3
    c2=$(<"$rb2")
    c3=$(<"$rb3")

    assert_match "Manjaro" "$c2" "Bare-metal runbook should mention Manjaro"
    assert_match "Active Bootloader:.*grub" "$c2" "Should list GRUB as active bootloader"
    assert_match "manjaro-root-3333" "$c2" "Root UUID correctly rendered"
    assert_match "grub-install" "$c2" "Should include grub-install instructions"
    assert_match "grub-mkconfig" "$c2" "Should include grub-mkconfig instructions"
    assert_match "Manjaro" "$c3" "Cloud runbook should mention Manjaro"
}

echo "=== Running Manjaro Integration Test ==="
run_test test_manjaro_grub "Runbooks generation for Manjaro with GRUB bootloader"
test_summary
