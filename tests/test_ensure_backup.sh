#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for _ensure_backup_mounted error handling
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helper.bash"

_setup_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    touch "$LOG_FILE"
    
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    export BACKUP_UUID="test-uuid-1234"
    export BACKUP_DEV="/dev/sdX1"
    export DRY_RUN=false
    
    # Mocks
    mock_cmd findmnt 'exit 1'
    mock_cmd mountpoint 'exit 1'
    mock_cmd mount 'exit 0'
    mock_cmd ui_yesno 'exit 0'
    mock_cmd effective_user 'echo walter'
    
    # Mock mktemp so it creates in TEST_TEMP_DIR
    mktemp() {
        command mktemp "$TEST_TEMP_DIR/fstab.tmp.XXXXXX"
    }
    export -f mktemp
    
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
}

test_ensure_backup_mkdir_fail() {
    _setup_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/wizard.sh" >/dev/null 2>&1 || true
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    
    # Make BACKUP_MOUNT unwritable
    touch "$BACKUP_MOUNT" # create it as a file so mkdir -p fails
    
    if _ensure_backup_mounted; then
        echo "Error: _ensure_backup_mounted should have failed" >&2
        return 1
    fi
    if ! grep -q "Failed to create" "$LOG_FILE"; then
        echo "Error: Should log mkdir failure" >&2
        cat "$LOG_FILE" >&2
        return 1
    fi
    rm -f "$BACKUP_MOUNT"
}

test_ensure_backup_cp_fstab_fail() {
    _setup_env
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/wizard.sh" >/dev/null 2>&1 || true
    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    
    # Mock cp to fail
    cp() {
        if [[ "$1" == "-p" && "$2" == "/etc/fstab" ]]; then
            return 1
        fi
        command cp "$@"
    }
    export -f cp
    
    if _ensure_backup_mounted; then
        echo "Error: _ensure_backup_mounted should have failed" >&2
        return 1
    fi
    if ! grep -q "Failed to copy /etc/fstab" "$LOG_FILE"; then
        echo "Error: Should log cp failure" >&2
        cat "$LOG_FILE" >&2
        return 1
    fi
}

run_tests
