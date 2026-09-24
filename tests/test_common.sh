#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/common.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "=== Running tests for lib/common.sh ==="
run_test test_layer_selected "Layer selection checks"
run_test test_logging "Logging to file"
run_test test_manifest_recording "Manifest recording and deduplication"
run_test test_template_render "Template rendering with variable substitution"
run_test test_template_render_shell_escaping "Template rendering shell escaping safety"
test_summary
