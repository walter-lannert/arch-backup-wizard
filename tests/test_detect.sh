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

echo "=== Running tests for lib/detect.sh ==="
run_test test_detect_distro "Distro detection"
run_test test_detect_aur_helper "AUR helper detection"
run_test test_detect_root_filesystem "Root filesystem detection"
run_test test_detect_bootloader "Bootloader detection"
test_summary
