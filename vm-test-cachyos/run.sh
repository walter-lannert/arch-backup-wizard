#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — In-VM Test Dispatcher
#
# Dispatches between automated test runner, manual interactive session,
# and code synchronization.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DO_SYNC=false
SYNC_ONLY=false
INTERACTIVE=false

for arg in "$@"; do
    case "$arg" in
        --sync)
            DO_SYNC=true
            ;;
        --sync-only)
            DO_SYNC=true
            SYNC_ONLY=true
            ;;
        --interactive|-i)
            INTERACTIVE=true
            ;;
        -h|--help)
            echo "Usage: ./run.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --sync             Sync repository code into VM, then run automated tests"
            echo "  --sync-only        Sync repository code into VM and exit"
            echo "  --interactive, -i  Launch interactive manual VM session (real dialog TUI)"
            echo "  -h, --help         Show this help message"
            echo ""
            echo "Default (no args): Directly boots the VM in automated snapshot mode and runs tests."
            echo ""
            echo "Direct scripts:"
            echo "  ./test.sh          Run automated test suite in snapshot mode"
            echo "  ./interactive.sh   Launch interactive session (supports --persist)"
            echo "  ./sync.sh          Sync workspace code to VM image"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg (use -h for help)"
            exit 1
            ;;
    esac
done

if [[ "$INTERACTIVE" == true ]]; then
    exec "$SCRIPT_DIR/interactive.sh"
fi

if [[ "$DO_SYNC" == true ]]; then
    "$SCRIPT_DIR/sync.sh"
    if [[ "$SYNC_ONLY" == true ]]; then
        exit 0
    fi
fi

exec "$SCRIPT_DIR/test.sh"
