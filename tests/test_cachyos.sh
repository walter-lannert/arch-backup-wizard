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

test_cachyos_systemd_boot() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export SETTINGS_FILE="$TEST_TEMP_DIR/settings.env"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="walter"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="cachy-root-1111"
    export DETECTED_EFI_UUID="cachy-efi-2222"
    export DETECTED_BOOTLOADER="systemd-boot"
    export DETECTED_HOSTNAME="cachy-gaming-rig"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="cachyos"
    export DETECTED_DISTRO="CachyOS"
    export DETECTED_SUBVOLUMES="@
@home
@root
@srv
@cache
@tmp
@log"
    export DETECTED_SUBVOL_MOUNTS="/home:@home /root:@root /srv:@srv /var/cache:@cache /var/tmp:@tmp /var/log:@log"
    export DETECTED_EFI_MOUNT="/boot"
    export BACKUP_UUID="backup-ssd-9999"
    
    export CLOUD_REMOTE="googledrive:"
    export CLOUD_OS_DIR="CachyOS_BareMetal_Clones"
    export CLOUD_PIKA_DIR="CachyOS_Pika_Backup"
    export CLOUD_AGE_KEY="/home/walter/.config/arch-backup-wizard/cloud_os.key"

    export WIZARD_DIR="$REPO_DIR"
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    export SELECTED_LAYERS=("1" "2" "3" "4" "5")
    export LAYER4_ENCRYPT="true"
    
    # Mock pacman to return CachyOS customized kernels
    mock_cmd pacman 'echo "linux-cachyos linux-cachyos-headers"'
    mock_cmd hostname 'echo cachy-gaming-rig'
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
    
    # Verify CachyOS specifics
    assert_match "CachyOS" "$c2" "Bare-metal runbook should mention CachyOS"
    assert_match "linux-cachyos" "$c2" "Bare-metal runbook should detect linux-cachyos kernel"
    assert_match "cachy-root-1111" "$c2" "Root UUID correctly rendered"
    assert_match "bootctl" "$c2" "Should include bootctl steps for systemd-boot"
    
    # Verify subvolumes list includes CachyOS layout
    assert_match "@home" "$c2" "Should restore @home subvolume"
    assert_match "@cache" "$c2" "Should restore @cache subvolume"
    assert_match "@log" "$c2" "Should restore @log subvolume"
    
    # Cloud runbook verification
    assert_match "CachyOS" "$c3" "Cloud runbook should mention CachyOS"
    assert_match "googledrive:" "$c3" "Cloud runbook should reference cloud remote"
    assert_match "age -d" "$c3" "Cloud runbook should include decryption command"
}

test_cachyos_limine_bootloader() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export SETTINGS_FILE="$TEST_TEMP_DIR/settings.env"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="walter"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="cachy-root-1111"
    export DETECTED_EFI_UUID="cachy-efi-2222"
    export DETECTED_BOOTLOADER="limine"
    export DETECTED_HOSTNAME="cachy-gaming-rig"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="cachyos"
    export DETECTED_DISTRO="CachyOS"
    export DETECTED_SUBVOLUMES="@
@home"
    export DETECTED_SUBVOL_MOUNTS="/home:@home"
    export DETECTED_EFI_MOUNT="/boot"
    export BACKUP_UUID="backup-ssd-9999"

    export WIZARD_DIR="$REPO_DIR"
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    export SELECTED_LAYERS=("1" "2")
    export LAYER4_ENCRYPT="false"
    
    mock_cmd pacman 'echo "linux-cachyos"'
    mock_cmd hostname 'echo cachy-gaming-rig'
    mock_cmd chown 'exit 0'
    mock_cmd awk 'exit 0'
    
    save_settings
    generate_runbooks

    local rb2="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"
    assert_file_exists "$rb2" "Layer 2 runbook should exist"
    
    local c2
    c2=$(<"$rb2")
    assert_match "Active Bootloader:.*limine" "$c2" "Should list Limine as active bootloader"
    assert_match "limine-mkinitcpio" "$c2" "Should include limine rebuild steps"
}

echo "=== Running CachyOS Integration Tests ==="
run_test test_cachyos_systemd_boot "Runbooks generation for CachyOS with systemd-boot & all 5 layers"
run_test test_cachyos_limine_bootloader "Runbooks generation for CachyOS with Limine bootloader"
test_summary
