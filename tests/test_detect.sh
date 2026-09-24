#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/detect.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helper.bash"

_setup_detect_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    touch "$LOG_FILE"
    export WIZARD_DIR="$REPO_DIR"

    # Default mocks
    mock_cmd findmnt 'echo "btrfs"'
    mock_cmd btrfs 'exit 0'
    mock_cmd lsblk 'exit 0'
    mock_cmd blkid 'exit 0'
}

# Test 1: Distro detection from /etc/os-release
test_detect_distro() {
    _setup_detect_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/detect.sh"

    detect_distro
    assert_ne "" "$DETECTED_DISTRO" "Distro should be detected"
    assert_ne "" "$DETECTED_DISTRO_ID" "Distro ID should be detected"
}

# Test 2: AUR helper detection with controlled mock
test_detect_aur_helper() {
    _setup_detect_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/detect.sh"

    # Scenario A: only paru available
    cmd_exists() { [[ "$1" == "paru" ]]; }
    detect_aur_helper
    assert_eq "paru" "$DETECTED_AUR_HELPER" "paru preferred when available"

    # Scenario B: only yay available
    cmd_exists() { [[ "$1" == "yay" ]]; }
    detect_aur_helper
    assert_eq "yay" "$DETECTED_AUR_HELPER" "yay selected when paru unavailable"

    # Scenario C: neither available
    cmd_exists() { return 1; }
    detect_aur_helper
    assert_eq "" "$DETECTED_AUR_HELPER" "empty when neither available"
}

# Test 3: Root filesystem detection
test_detect_root_filesystem() {
    _setup_detect_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/detect.sh"

    mock_cmd findmnt 'echo "btrfs"'
    detect_root_filesystem
    assert_eq "btrfs" "$DETECTED_ROOT_FS" "Root filesystem detected as btrfs"

    mock_cmd findmnt 'echo "ext4"'
    detect_root_filesystem
    assert_eq "ext4" "$DETECTED_ROOT_FS" "Root filesystem detected as ext4"
}

# Test 4: Bootloader detection
test_detect_bootloader() {
    _setup_detect_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/detect.sh"

    detect_bootloader
    # On this machine, it should detect a valid known bootloader (limine, systemd-boot, grub, or unknown)
    assert_ne "" "$DETECTED_BOOTLOADER" "Bootloader should be detected"
}

# Test 5: System devices detection scopes to root UUID and excludes secondary drives
test_detect_system_devices() {
    _setup_detect_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/detect.sh"

    export DETECTED_ROOT_UUID="root-uuid-1111"
    export DETECTED_ROOT_DEV="/dev/nvme0n1p2"

    # shellcheck disable=SC2016
    mock_cmd findmnt '
        for arg in "$@"; do
            if [[ "$arg" == "UUID=root-uuid-1111" ]]; then
                echo "/"
                echo "/home"
                return 0
            fi
        done
        if [[ "$*" == *"-o FSTYPE"* ]]; then
            echo "btrfs"
            return 0
        fi
        if [[ "$*" == *"-o SOURCE"* ]]; then
            echo "/dev/nvme0n1p2"
            return 0
        fi
        return 0
    '
    mock_cmd btrfs 'echo "path /dev/nvme0n1p2"'
    # shellcheck disable=SC2016
    mock_cmd lsblk '
        if [[ "$*" == *"/dev/nvme0n1p2"* ]]; then
            echo "/dev/nvme0n1p2"
            echo "/dev/nvme0n1"
            return 0
        fi
        return 0
    '
    mock_cmd swapon 'echo "/dev/zram0"'

    detect_system_devices

    # Verify root NVMe partitions are classified as system devices
    local found_nvme=false
    local found_sda=false
    local dev
    for dev in "${DETECTED_SYSTEM_DEVS[@]}"; do
        [[ "$dev" == "/dev/nvme0n1p2" ]] && found_nvme=true
        [[ "$dev" == "/dev/sda1" ]] && found_sda=true
    done

    assert_eq "true" "$found_nvme" "Root device /dev/nvme0n1p2 must be in DETECTED_SYSTEM_DEVS"
    assert_eq "false" "$found_sda" "Secondary device /dev/sda1 must NOT be in DETECTED_SYSTEM_DEVS"
}

echo "=== Running tests for lib/detect.sh ==="
run_test test_detect_distro "Distro detection"
run_test test_detect_aur_helper "AUR helper detection"
run_test test_detect_root_filesystem "Root filesystem detection"
run_test test_detect_bootloader "Bootloader detection"
run_test test_detect_system_devices "System devices exclusion scoping"
test_summary
