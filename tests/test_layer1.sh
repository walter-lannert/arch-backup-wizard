#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/layer1_snapper.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export TEST_TEMP_DIR_OVERRIDE="${TEST_TEMP_DIR:-}" # test_helper sets it, wait, we don't know it yet!
# Actually we can't set it to TEST_TEMP_DIR because test_helper creates TEST_TEMP_DIR.
# Let's just set it to /tmp/abw_mock_snap_dir
export ABW_TEST_SNAP_DIR="/tmp/abw_mock_snap_dir_$$"
export ABW_TEST_SNAPPER_ROOT_CONF="/tmp/abw_mock_snapper_root_conf_$$"

source "$SCRIPT_DIR/test_helper.bash"

_setup_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    touch "$LOG_FILE"
    
    mock_cmd mountpoint 'exit 1'
    mock_cmd findmnt 'exit 1'
    mock_cmd snapper 'exit 0'
    mock_cmd umount 'exit 0'
    mock_cmd rmdir 'exit 0'
    mock_cmd ui_infobox 'exit 0'
    mock_cmd ui_yesno 'exit 1'
    
    export BTRBK_CONF="$TEST_TEMP_DIR/btrbk.conf"
    export BTRBK_SNAPSHOT_DIR="/.snapshots_btrbk"
    
    # shellcheck disable=SC2329
    install_layer_packages() {
        return 0
    }
}

test_layer1_nested_snapshots_aborted() {
    _setup_env
    mkdir -p "$ABW_TEST_SNAP_DIR"
    
    source "$REPO_DIR/lib/common.sh"
    source "$REPO_DIR/lib/layer1_snapper.sh"
    
    # Mock btrfs to pretend ABW_TEST_SNAP_DIR is a subvol with nested snapshots
    # shellcheck disable=SC2329
    btrfs() {
        if [[ "$1" == "subvolume" && "$2" == "show" && "$3" == "$SNAP_DIR" ]]; then
            return 0
        fi
        if [[ "$1" == "subvolume" && "$2" == "list" && "$3" == "-o" && "$4" == "$SNAP_DIR" ]]; then
            echo "ID 257 gen 10 top level 5 path $SNAP_DIR/1"
            echo "ID 258 gen 10 top level 5 path $SNAP_DIR/2"
            return 0
        fi
        command btrfs "$@" || true
    }
    
    # Mock ui_confirm_destructive to ABORT (return 1)
    # shellcheck disable=SC2329
    ui_confirm_destructive() {
        return 1
    }
    
    if setup_layer1; then
        echo "Error: setup_layer1 should have aborted" >&2
        return 1
    fi
    
    if ! grep -q "Cannot proceed with Snapper setup." "$LOG_FILE"; then
        echo "Error: Should abort due to ui_confirm_destructive rejection" >&2
        cat "$LOG_FILE" >&2
        return 1
    fi
}

run_tests
rm -rf "$ABW_TEST_SNAP_DIR" "$ABW_TEST_SNAPPER_ROOT_CONF"
