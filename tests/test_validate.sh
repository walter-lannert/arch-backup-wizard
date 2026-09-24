#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/validate.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helper.bash"

# ── Shared test environment setup ─────────────────────────────────────────────
_setup_validate_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/unmanaged_orig.txt"
    export DETECTED_USER="testuser"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DIALOG_CMD=""
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    export DETECTED_BOOTLOADER=""
    export DETECTED_HOSTNAME="testhost"
    export BORG_INFO_TIMEOUT=2

    # Override functions from other lib modules
    # shellcheck disable=SC2329
    pkg_is_installed() { return 1; }
    # shellcheck disable=SC2329
    ui_msgbox() { :; }
    # shellcheck disable=SC2329
    detect_dialog() { DIALOG_CMD=""; }

    # Mock external commands (prepended to PATH via mock_cmd)
    mock_cmd systemctl 'exit 1'
    mock_cmd sudo 'exit 0'
    mock_cmd snapper 'exit 1'
    mock_cmd btrbk 'exit 1'
    mock_cmd borg 'exit 1'
    mock_cmd rclone 'exit 1'
    mock_cmd getent 'echo "testuser:x:1000:1000::/home/testuser:/bin/bash"'
    mock_cmd logname 'echo "testuser"'
    # Mock awk so the /etc/fstab check finds a valid "nofail" entry
    mock_cmd awk 'echo "UUID=test /backup ext4 defaults,nofail 0 2"'
}

# ── Test 1: All layers skipped ───────────────────────────────────────────────
test_all_layers_skipped() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=()

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "0" "$rc" "run_validation should succeed when no layers selected"
    assert_match "Layer 1: Snapper.*Skipped" "$output" "Layer 1 should be skipped"
    assert_match "Layer 2: btrbk.*Skipped" "$output" "Layer 2 should be skipped"
    assert_match "Layer 3: Pika Backup.*Skipped" "$output" "Layer 3 should be skipped"
    assert_match "Layer 4: Cloud Offsite.*Skipped" "$output" "Layer 4 should be skipped"
    assert_match "Layer 5: Deep Storage.*Skipped" "$output" "Layer 5 should be skipped"
    assert_match "All checks passed" "$output" "Should report all checks passed"
}

# ── Test 2: Layer 5 happy path ───────────────────────────────────────────────
test_layer5_happy_path() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=(5)
    mkdir -p "$BACKUP_MOUNT/Deep Storage"

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "0" "$rc" "run_validation should succeed for Layer 5 happy path"
    assert_match "Layer 5: Deep Storage.*OK" "$output" "Layer 5 should pass"
    assert_match "All checks passed" "$output" "Should report all checks passed"
}

# ── Test 3: Layer 5 missing directory ────────────────────────────────────────
test_layer5_missing_directory() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=(5)
    # Intentionally do NOT create the Deep Storage directory

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "1" "$rc" "run_validation should fail for missing Layer 5 directory"
    assert_match "Layer 5: Deep Storage.*ISSUES" "$output" "Layer 5 should show issues"
    assert_match "Issues were detected" "$output" "Should report issues detected"
}

# ── Test 4: Layer 2 package not installed ────────────────────────────────────
test_layer2_package_missing() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=(2)
    # pkg_is_installed is mocked to return 1 (not installed)

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "1" "$rc" "run_validation should fail when btrbk package missing"
    assert_match "Layer 2: btrbk.*ISSUES" "$output" "Layer 2 should show issues"
    assert_match "Issues were detected" "$output" "Should report issues detected"
}

# ── Test 5: Layer 1 package not installed ────────────────────────────────────
test_layer1_package_missing() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=(1)
    # pkg_is_installed is mocked to return 1 (not installed)

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "1" "$rc" "run_validation should fail when snapper package missing"
    assert_match "Layer 1: Snapper.*ISSUES" "$output" "Layer 1 should show issues"
    assert_match "Issues were detected" "$output" "Should report issues detected"
}

# ── Test 6: Mixed layers — partial failure ───────────────────────────────────
test_mixed_layers_partial_failure() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    SELECTED_LAYERS=(2 5)
    mkdir -p "$BACKUP_MOUNT/Deep Storage"
    # Layer 2 will fail (pkg not installed), Layer 5 will pass

    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "1" "$rc" "run_validation should fail due to Layer 2 issues"
    assert_match "Layer 2: btrbk.*ISSUES" "$output" "Layer 2 should show issues"
    assert_match "Layer 5: Deep Storage.*OK" "$output" "Layer 5 should pass"
    assert_match "Issues were detected" "$output" "Should report issues detected"
}

# ── Test 7: CLI mode bypasses dialog and prints to stdout ─────────────────────
test_validate_cli_mode_skips_dialog() {
    _setup_validate_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/validate.sh"

    VALIDATE=true
    local ui_msgbox_invoked=false
    ui_msgbox() {
        ui_msgbox_invoked=true
    }

    SELECTED_LAYERS=()
    local output rc=0
    output=$(run_validation 2>/dev/null) || rc=$?

    assert_eq "0" "$rc" "run_validation should return 0 in CLI mode when all checks pass"
    assert_match "All checks passed" "$output" "Should print dashboard to stdout"
    assert_eq "false" "$ui_msgbox_invoked" "ui_msgbox must NOT be called in CLI mode"
}

echo "=== Running tests for lib/validate.sh ==="
run_test test_all_layers_skipped "All layers skipped (no selection)"
run_test test_layer5_happy_path "Layer 5 happy path (directory exists)"
run_test test_layer5_missing_directory "Layer 5 degraded (directory missing)"
run_test test_layer2_package_missing "Layer 2 failure (package not installed)"
run_test test_layer1_package_missing "Layer 1 failure (package not installed)"
run_test test_mixed_layers_partial_failure "Mixed layers (partial failure)"
run_test test_validate_cli_mode_skips_dialog "CLI mode bypasses dialog UI"
test_summary
