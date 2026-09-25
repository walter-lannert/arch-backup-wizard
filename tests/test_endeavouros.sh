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

test_endeavouros_systemd_boot() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export SETTINGS_FILE="$TEST_TEMP_DIR/settings.env"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="testuser"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="aaaa-bbbb-cccc"
    export DETECTED_EFI_UUID="dddd-eeee-ffff"
    export DETECTED_BOOTLOADER="systemd-boot"
    export DETECTED_HOSTNAME="testhost"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="standard"
    export DETECTED_DISTRO="EndeavourOS"
    export DETECTED_SUBVOLUMES="@
@home
@snapshots"
    export DETECTED_SUBVOL_MOUNTS="/home:@home"
    export DETECTED_EFI_MOUNT="/efi"
    export BACKUP_UUID="1111-2222-3333"
    
    export CLOUD_REMOTE="cloud:"
    export CLOUD_OS_DIR="os_backup"
    export CLOUD_PIKA_DIR="pika_backup"
    export CLOUD_AGE_KEY="/root/cloud_os.key"

    export WIZARD_DIR="$REPO_DIR"
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    # We need to set layer selection.
    export SELECTED_LAYERS=("1" "2" "3" "4" "5")
    export LAYER4_ENCRYPT="true"
    
    # Mock commands
    mock_cmd pacman 'echo "linux"'
    mock_cmd hostname 'echo testhost'
    mock_cmd chown 'exit 0'
    mock_cmd awk 'exit 0'
    
    # Save settings to simulate wizard behavior
    save_settings

    # Call generate_runbooks
    generate_runbooks

    local rb1="$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt"
    local rb2="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"
    
    assert_file_exists "$rb1" "Layer 1 runbook should exist"
    assert_file_exists "$rb2" "Layer 2 runbook should exist"
    
    local c2
    c2=$(<"$rb2")
    
    # Check EndeavourOS specific wording
    assert_match "EndeavourOS" "$c2" "Should mention EndeavourOS"
    assert_match "bootctl" "$c2" "Should use bootctl for systemd-boot"
}

echo "=== Running EndeavourOS systemd-boot Integration Test ==="
run_test test_endeavouros_systemd_boot "Runbooks generation for EndeavourOS with systemd-boot"
test_summary
