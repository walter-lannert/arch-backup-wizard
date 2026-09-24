#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/packages.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helper.bash"

# Shared mock setup
_setup_pkg_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    touch "$LOG_FILE"
    export DETECTED_USER="walter"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_BOOTLOADER="systemd-boot"
    export DETECTED_AUR_HELPER="yay"
    export WIZARD_DIR="$REPO_DIR"

    # Default mocks
    # shellcheck disable=SC2016
    mock_cmd sudo '
while [[ $# -gt 0 && "$1" == -* ]]; do
    shift
done
if [[ $# -gt 0 ]]; then
    exec "$@"
fi
exit 0'
    mock_cmd pacman 'exit 0'
    mock_cmd yay 'exit 0'
    mock_cmd paru 'exit 0'
}

# Test 1: Package name validation
test_validate_pkg_name() {
    _setup_pkg_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/packages.sh"

    assert_success "_validate_pkg_name 'btrfs-progs'" "Valid package name btrfs-progs"
    assert_success "_validate_pkg_name 'snapper_git'" "Valid package name with underscore"
    assert_success "_validate_pkg_name 'gcc-libs+extra'" "Valid package name with plus"
    assert_failure "_validate_pkg_name 'linux-headers@6.1'" "Reject package name with at sign"
    assert_failure "_validate_pkg_name 'bad;rm -rf /'" "Reject package name with semicolon"
    # shellcheck disable=SC2016
    assert_failure '_validate_pkg_name "bad\$(whoami)"' "Reject package name with command substitution"
    assert_failure "_validate_pkg_name 'bad package'" "Reject package name with whitespace"
}

# Test 2: Package installation via pacman
test_pkg_is_installed() {
    _setup_pkg_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/packages.sh"

    # Mock pacman -Qi and -Qkk to succeed only for 'installed-pkg'
    mock_cmd pacman '
if [[ "$*" == *"-Qi installed-pkg"* ]] || [[ "$*" == *"-Qkk installed-pkg"* ]]; then
    exit 0
else
    exit 1
fi'

    assert_success "pkg_is_installed 'installed-pkg'" "installed-pkg should be detected as installed"
    assert_failure "pkg_is_installed 'missing-pkg'" "missing-pkg should be detected as missing"
}

# Test 3: Layer package mapping
test_get_layer_packages() {
    _setup_pkg_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/packages.sh"

    local pkgs_l2 pkgs_l3 pkgs_l4 pkgs_l5
    pkgs_l2=$(get_layer_packages 2)
    pkgs_l3=$(get_layer_packages 3)
    pkgs_l4=$(get_layer_packages 4)
    pkgs_l5=$(get_layer_packages 5)

    assert_match "btrbk" "$pkgs_l2" "Layer 2 includes btrbk"
    assert_match "pika-backup" "$pkgs_l3" "Layer 3 includes pika-backup"
    assert_match "rclone" "$pkgs_l4" "Layer 4 includes rclone"
    assert_match "age" "$pkgs_l4" "Layer 4 includes age"
    assert_eq "" "$pkgs_l5" "Layer 5 requires no extra packages"
}

# Test 4: Layer 1 systemd-boot handling (no snapshot AUR helper required)
test_layer1_systemd_boot() {
    _setup_pkg_env
    export DETECTED_BOOTLOADER="systemd-boot"
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/ui.sh"
    source "$REPO_DIR/lib/packages.sh"

    mock_cmd pacman 'exit 0'

    assert_success "install_layer_packages 1" "Layer 1 under systemd-boot should succeed with base packages"
}

echo "=== Running tests for lib/packages.sh ==="
run_test test_validate_pkg_name "Package name validation"
run_test test_pkg_is_installed "Package installation check"
run_test test_get_layer_packages "Layer package mapping"
run_test test_layer1_systemd_boot "Layer 1 systemd-boot base package handling"
test_summary
