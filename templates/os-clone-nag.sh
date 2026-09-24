#!/bin/bash
set -uo pipefail
# Only run if inside a graphical desktop session
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exit 0
fi

# Ensure zenity is available
if ! command -v zenity >/dev/null 2>&1; then
    exit 0
fi

# Prevent concurrent execution across multiple simultaneous shell startups (tmux, tabs, etc.)
LOCK_FILE="{{DETECTED_HOME}}/.os_clone_nag.lock"
exec 9>"$LOCK_FILE" || exit 0
if ! flock -n 9; then
    printf 'os-clone-nag: could not acquire lock (flock rc=%d)\n' "$?" \
        >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
    exit 0
fi

YEAR=$(date +%Y)
MONTH=$(date +%m)
DAY=$(date +%-d)

if [ "$DAY" -lt 15 ]; then
    PERIOD="1"
else
    PERIOD="2"
fi

CURRENT_TARGET="${YEAR}-${MONTH}-P${PERIOD}"
LAST_RUN_FILE="{{DETECTED_HOME}}/.last_cloud_run"

LAST_RUN=""
if [ -f "$LAST_RUN_FILE" ]; then
    LAST_RUN=$(cat "$LAST_RUN_FILE")
fi

if [ "$CURRENT_TARGET" != "$LAST_RUN" ]; then
    sleep 5

    ZENITY_RC=0
    timeout 120 zenity --question --title="OS Cloud Backup Due" \
        --text="Your bi-weekly OS clone cloud backup is due.\n\nWould you like to run it now?" \
        --ok-label="Run Now" \
        --cancel-label="Later" || ZENITY_RC=$?

    if [ "$ZENITY_RC" -eq 0 ]; then
        {{DETECTED_TERMINAL_CMD}} bash -c "rc=0; \"{{DETECTED_HOME}}/.os_cloud_backup.sh\" || rc=\$?; if [ \$rc -eq 0 ]; then printf '%s\n' \"$CURRENT_TARGET\" > \"{{DETECTED_HOME}}/.last_cloud_run\" || echo 'os-clone-nag: WARNING: backup succeeded but could not stamp .last_cloud_run' >&2; fi; exit \$rc" || true
    elif [ "$ZENITY_RC" -ne 1 ]; then
        printf 'os-clone-nag: zenity failed (rc=%d)\n' "$ZENITY_RC" >&2
    fi
fi

# Clean up lock file (best-effort)
flock -u 9 2>/dev/null || true
rm -f "$LOCK_FILE" 2>/dev/null || true
