#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/common.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_helper.bash
source "$SCRIPT_DIR/test_helper.bash"

# Test 1: Layer selection checks
test_layer_selected() {
    source "$REPO_DIR/lib/common.sh"
    SELECTED_LAYERS=("1" "3" "5")

    assert_success "layer_selected 1" "Layer 1 should be selected"
    assert_success "layer_selected 3" "Layer 3 should be selected"
    assert_success "layer_selected 5" "Layer 5 should be selected"
    assert_failure "layer_selected 2" "Layer 2 should not be selected"
    assert_failure "layer_selected 4" "Layer 4 should not be selected"
}

# Test 2: Logging functionality
test_logging() {
    export LOG_FILE="$TEST_TEMP_DIR/test_wizard.log"
    source "$REPO_DIR/lib/common.sh"

    log_info "Test info message"
    log_warn "Test warn message"
    log_error "Test error message"
    log_success "Test success message"

    assert_file_exists "$LOG_FILE" "Log file should be created"
    local content
    content=$(<"$LOG_FILE")
    assert_match "\[INFO \] Test info message" "$content" "Info message logged"
    assert_match "\[WARN \] Test warn message" "$content" "Warn message logged"
    assert_match "\[ERROR\] Test error message" "$content" "Error message logged"
    assert_match "\[OK   \] Test success message" "$content" "Success message logged"
}

# Test 3: Manifest recording
test_manifest_recording() {
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    source "$REPO_DIR/lib/common.sh"

    record_manifest "/etc/test1.conf"
    record_manifest "/etc/test2.conf"
    record_manifest "/etc/test1.conf" # duplicate check

    assert_file_exists "$MANIFEST_FILE" "Manifest file must exist"
    local lines
    lines=$(wc -l < "$MANIFEST_FILE")
    assert_eq "2" "$lines" "Manifest should not contain duplicates"
}

# Test 4: Template rendering with variable substitution
test_template_render() {
    source "$REPO_DIR/lib/common.sh"

    local tpl="$TEST_TEMP_DIR/sample.conf.in"
    local out="$TEST_TEMP_DIR/sample.conf"

    cat <<'EOF' > "$tpl"
# Generated config
TARGET="{{TARGET_PATH}}"
USER="{{DETECTED_USER}}"
PORT={{SERVICE_PORT}}
EOF

    export TARGET_PATH="/mnt/backup drive/path"
    export DETECTED_USER="walter"
    export SERVICE_PORT="8080"

    template_render "$tpl" "$out"
    assert_file_exists "$out" "Rendered output file must exist"

    local rendered
    rendered=$(<"$out")
    assert_match 'TARGET="/mnt/backup drive/path"' "$rendered" "Target path substituted"
    assert_match 'USER="walter"' "$rendered" "User substituted"
    assert_match 'PORT=8080' "$rendered" "Port substituted"
}

# Test 5: Template rendering shell escaping safety
test_template_render_shell_escaping() {
    source "$REPO_DIR/lib/common.sh"

    local tpl="$TEST_TEMP_DIR/script.sh.in"
    local out="$TEST_TEMP_DIR/script.sh"

    cat <<'EOF' > "$tpl"
#!/bin/sh
MSG="{{SECRET_MESSAGE}}"
DIR="{{SPECIAL_DIR}}"
EOF

    # shellcheck disable=SC2016
    export SECRET_MESSAGE='Contains $VAR, "quotes", and `commands` and \backslash'
    # shellcheck disable=SC2016
    export SPECIAL_DIR='/home/walter/test$dir'

    template_render "$tpl" "$out"
    assert_file_exists "$out" "Rendered script must exist"

    # Verify script has valid shell syntax
    assert_success "bash -n '$out'" "Rendered shell script should pass bash -n syntax check"
}

# Test 6: Snapshot naming contract
test_subvolume_to_snapshot_name() {
    source "$REPO_DIR/lib/common.sh"

    local snap1 snap2 snap3
    snap1=$(subvolume_to_snapshot_name "@")
    snap2=$(subvolume_to_snapshot_name "@home")
    snap3=$(subvolume_to_snapshot_name "var/log")

    # Assert deterministic prefix and hash length
    assert_match "^@_[0-9a-f]{8}$" "$snap1" "Root snapshot name format"
    assert_match "^@home_[0-9a-f]{8}$" "$snap2" "Home snapshot name format"
    assert_match "^var_log_[0-9a-f]{8}$" "$snap3" "Nested path sanitization"

    # Assert collision resistance between distinct subvolumes
    local snap_a_b snap_ab
    snap_a_b=$(subvolume_to_snapshot_name "a/b")
    snap_ab=$(subvolume_to_snapshot_name "a_b")
    if [[ "$snap_a_b" == "$snap_ab" ]]; then
        test_failed "Collision detected: a/b and a_b mapped to same snapshot name $snap_a_b"
    fi
}

# Test 7: Template rendering rejects unset variables
test_template_render_rejects_unset() {
    source "$REPO_DIR/lib/common.sh"

    local tpl="$TEST_TEMP_DIR/strict.conf.in"
    local out="$TEST_TEMP_DIR/strict.conf"

    cat <<'EOF' > "$tpl"
DEFINED="{{MY_DEFINED_VAR}}"
UNDEFINED="{{MY_NONEXISTENT_VAR}}"
EOF

    export MY_DEFINED_VAR="exists"
    unset MY_NONEXISTENT_VAR || true

    local rc=0
    template_render "$tpl" "$out" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "template_render should fail when a placeholder variable is unset"
}

echo "=== Running tests for lib/common.sh ==="
run_test test_layer_selected "Layer selection checks"
run_test test_logging "Logging to file"
run_test test_manifest_recording "Manifest recording and deduplication"
run_test test_template_render "Template rendering with variable substitution"
run_test test_template_render_shell_escaping "Template rendering shell escaping safety"
run_test test_subvolume_to_snapshot_name "Snapshot naming contract and collision avoidance"
run_test test_template_render_rejects_unset "Template rendering rejects unset variables"
test_summary
