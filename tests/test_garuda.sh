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

test_garuda_grub() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export SETTINGS_FILE="$TEST_TEMP_DIR/settings.env"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="garuda"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="garuda-root-7777"
    export DETECTED_EFI_UUID="garuda-efi-8888"
    export DETECTED_BOOTLOADER="grub"
    export DETECTED_HOSTNAME="garuda-dr460nized"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="garuda"
    export DETECTED_DISTRO="Garuda"
    export DETECTED_SUBVOLUMES="@
@home
@root
@srv
@cache
@tmp
@log"
    export DETECTED_SUBVOL_MOUNTS="/home:@home /root:@root /srv:@srv /var/cache:@cache /var/tmp:@tmp /var/log:@log"
    export DETECTED_EFI_MOUNT="/boot/efi"
    export BACKUP_UUID="garuda-backup-9999"

    export CLOUD_REMOTE="garudaremote:"
    export CLOUD_OS_DIR="Garuda_Clones"
    export CLOUD_PIKA_DIR="Garuda_Pika"
    export CLOUD_AGE_KEY="/root/cloud_os.key"

    export WIZARD_DIR="$REPO_DIR"
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    export SELECTED_LAYERS=("1" "2" "3" "4" "5")
    export LAYER4_ENCRYPT="true"

    # Garuda uses the zen kernel by default
    mock_cmd pacman 'echo "linux-zen linux-zen-headers amd-ucode"'
    mock_cmd hostname 'echo garuda-dr460nized'
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

    assert_match "Garuda" "$c2" "Bare-metal runbook should mention Garuda"
    assert_match "linux-zen" "$c2" "Bare-metal runbook should detect linux-zen kernel"
    assert_match "Active Bootloader:.*grub" "$c2" "Should list GRUB as active bootloader"
    assert_match "garuda-root-7777" "$c2" "Root UUID correctly rendered"
    assert_match "grub-install" "$c2" "Should include grub-install instructions"
    assert_match "@cache" "$c2" "Should restore @cache subvolume"
    assert_match "@log" "$c2" "Should restore @log subvolume"
    assert_match "Garuda" "$c3" "Cloud runbook should mention Garuda"
}

echo "=== Running Garuda Linux Integration Test ==="
run_test test_garuda_grub "Runbooks generation for Garuda Linux with GRUB & linux-zen"
test_summary
