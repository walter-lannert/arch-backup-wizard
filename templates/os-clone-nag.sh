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

# Detect network filesystem and warn about flock reliability
FS_TYPE=$(stat -f -c %T "{{DETECTED_HOME}}" 2>/dev/null || echo "unknown")
case "$FS_TYPE" in
    nfs|nfs4|cifs|smbfs|fuse.sshfs)
        printf 'os-clone-nag: WARNING: home on network FS (%s); flock may be unreliable\n' "$FS_TYPE" \
            >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
        ;;
esac

# Prevent concurrent execution across multiple simultaneous shell startups (tmux, tabs, etc.)
LOCK_FILE="{{DETECTED_HOME}}/.os_clone_nag.lock"
exec 9>"$LOCK_FILE" || exit 0
flock -n 9
FL_RC=$?
if [ "$FL_RC" -ne 0 ]; then
    printf 'os-clone-nag: could not acquire lock (flock rc=%d)\n' "$FL_RC" \
        >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
    exit 0
fi

YEAR=$(date +%Y) || { printf 'os-clone-nag: FATAL: date +%Y failed\n' >&2; exit 1; }
MONTH=$(date +%m) || { printf 'os-clone-nag: FATAL: date +%m failed\n' >&2; exit 1; }
DAY=$(date +%d) || { printf 'os-clone-nag: FATAL: date +%d failed\n' >&2; exit 1; }
case "$DAY" in
    ''|*[!0-9]*) printf 'os-clone-nag: FATAL: invalid day value: %q\n' "$DAY" >&2; exit 1 ;;
esac
DAY=$((10#$DAY))

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
    IN_PROGRESS_FILE="{{DETECTED_HOME}}/.os_cloud_backup.in_progress"
    if [ -f "$IN_PROGRESS_FILE" ]; then
        # Treat marker as stale if older than 4 hours (backup should never take that long)
        STALE_THRESHOLD=$((4 * 3600))
        NOW_EPOCH=$(date +%s)
        FILE_EPOCH=$(stat -c %Y "$IN_PROGRESS_FILE" 2>/dev/null || echo 0)
        AGE=$((NOW_EPOCH - FILE_EPOCH))
        if [ "$AGE" -gt "$STALE_THRESHOLD" ]; then
            printf 'os-clone-nag: removing stale in-progress marker (age=%ds)\n' "$AGE" \
                >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
            rm -f "$IN_PROGRESS_FILE" 2>/dev/null || true
        else
            flock -u 9 2>/dev/null || true
            rm -f "$LOCK_FILE" 2>/dev/null || true
            exit 0
        fi
    fi

    sleep 5

    ZENITY_RC=0
    timeout --kill-after=10 120 zenity --question --title="OS Cloud Backup Due" \
        --text="Your scheduled OS clone cloud backup is due.\n\nWould you like to run it now?" \
        --ok-label="Run Now" \
        --cancel-label="Later" || ZENITY_RC=$?

    if [ "$ZENITY_RC" -eq 0 ]; then
        # Create in-progress marker BEFORE spawning terminal (closes TOCTOU race)
        if ! touch "$IN_PROGRESS_FILE" 2>/dev/null; then
            printf 'os-clone-nag: FATAL: cannot create in-progress marker, aborting\n' >&2
            printf 'os-clone-nag: FATAL: cannot create in-progress marker at %s\n' "$(date -Iseconds)" \
                >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
        else
            OCN_HOME="{{DETECTED_HOME}}" OCN_TARGET="$CURRENT_TARGET" \
            {{DETECTED_TERMINAL_CMD}} setsid bash -c 'IP="$OCN_HOME/.os_cloud_backup.in_progress"; rc=0; "$OCN_HOME/.os_cloud_backup.sh" || rc=$?; rm -f "$IP" 2>/dev/null || true; if [ "$rc" -eq 0 ]; then printf "%s\n" "$OCN_TARGET" > "$OCN_HOME/.last_cloud_run" || echo "os-clone-nag: WARNING: backup succeeded but could not stamp .last_cloud_run" >&2; fi; exit "$rc"' \
            || { rm -f "$IN_PROGRESS_FILE" 2>/dev/null || true; printf 'os-clone-nag: WARNING: failed to launch backup terminal (rc=%d)\n' "$?" >&2; printf 'os-clone-nag: WARNING: failed to launch backup terminal (rc=%d) at %s\n' "$?" "$(date -Iseconds)" >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null; }
        fi
    elif [ "$ZENITY_RC" -ne 1 ]; then
        printf 'os-clone-nag: zenity failed (rc=%d)\n' "$ZENITY_RC" >&2
        printf 'os-clone-nag: zenity failed (rc=%d) at %s\n' "$ZENITY_RC" "$(date -Iseconds)" \
            >> "{{DETECTED_HOME}}/.os_clone_nag.log" 2>/dev/null
    fi
fi

# Clean up lock file (best-effort)
flock -u 9 2>/dev/null || true
rm -f "$LOCK_FILE" 2>/dev/null || true
