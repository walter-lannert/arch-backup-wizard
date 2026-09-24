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

# Ensure flock is available
if ! command -v flock >/dev/null 2>&1; then
    exit 0
fi

# Dedicated directory for lock and log (less likely to be swept by dotfile syncs)
LOCK_DIR="{{DETECTED_HOME}}/.os_clone_nag"
mkdir -p "$LOCK_DIR" 2>/dev/null || exit 0
_LOG_FILE="$LOCK_DIR/os_clone_nag.log"

# Detect network filesystem and warn about flock reliability
FS_TYPE=$(stat -f -c %T "{{DETECTED_HOME}}" 2>/dev/null || echo "unknown")
case "$FS_TYPE" in
    nfs|nfs4|cifs|smbfs|fuse.sshfs)
        printf 'os-clone-nag: WARNING: home on network FS (%s); flock may be unreliable\n' "$FS_TYPE" \
            >> "$_LOG_FILE" 2>/dev/null
        ;;
esac

# Prevent concurrent execution across multiple simultaneous shell startups (tmux, tabs, etc.)
LOCK_FILE="$LOCK_DIR/lock"
exec 9>"$LOCK_FILE" || exit 0
flock -n 9
FL_RC=$?
if [ "$FL_RC" -ne 0 ]; then
    printf 'os-clone-nag: could not acquire lock (flock rc=%d)\n' "$FL_RC" \
        >> "$_LOG_FILE" 2>/dev/null
    exit 0
fi

# Cap log file at 1 MiB to prevent unbounded growth
if [ -f "$_LOG_FILE" ] && [ "$(stat -c %s "$_LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    : > "$_LOG_FILE" 2>/dev/null || true
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
    LAST_RUN=$(tr -d '[:space:]' < "$LAST_RUN_FILE" 2>/dev/null)
fi

if [ "$CURRENT_TARGET" != "$LAST_RUN" ]; then
    IN_PROGRESS_FILE="{{DETECTED_HOME}}/.os_cloud_backup.in_progress"
    if [ -f "$IN_PROGRESS_FILE" ]; then
        # Treat marker as stale if older than 4 hours (backup should never take that long)
        STALE_THRESHOLD=$((4 * 3600))
        NOW_EPOCH=$(date +%s 2>/dev/null) || { flock -u 9 2>/dev/null || true; exit 0; }
        case "$NOW_EPOCH" in ''|*[!0-9]*) flock -u 9 2>/dev/null || true; exit 0 ;; esac
        FILE_EPOCH=$(stat -c %Y "$IN_PROGRESS_FILE" 2>/dev/null)
        if [ -z "$FILE_EPOCH" ]; then
            # Cannot determine age; treat as in-progress (fail-safe: do NOT remove)
            flock -u 9 2>/dev/null || true
            exit 0
        fi
        AGE=$((NOW_EPOCH - FILE_EPOCH))
        if [ "$AGE" -gt "$STALE_THRESHOLD" ]; then
            if pgrep -f "\.os_cloud_backup\.sh" >/dev/null 2>&1; then
                printf 'os-clone-nag: marker stale (%ds) but backup process still alive; NOT removing\n' "$AGE" \
                    >> "$_LOG_FILE" 2>/dev/null
                flock -u 9 2>/dev/null || true
                exit 0
            fi
            printf 'os-clone-nag: removing stale in-progress marker (age=%ds)\n' "$AGE" \
                >> "$_LOG_FILE" 2>/dev/null
            rm -f "$IN_PROGRESS_FILE" 2>/dev/null
        else
            flock -u 9 2>/dev/null || true
            exit 0
        fi
    fi

    sleep 2

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
                >> "$_LOG_FILE" 2>/dev/null
            flock -u 9 2>/dev/null || true
            exit 1
        else
            OCN_HOME="{{DETECTED_HOME}}" OCN_TARGET="$CURRENT_TARGET" \
            {{DETECTED_TERMINAL_CMD}} setsid bash -c 'IP="$OCN_HOME/.os_cloud_backup.in_progress"; rc=0; if [ ! -x "$OCN_HOME/.os_cloud_backup.sh" ]; then printf "os-clone-nag: ERROR: %s/.os_cloud_backup.sh is missing or not executable\n" "$OCN_HOME" >&2; rc=127; else "$OCN_HOME/.os_cloud_backup.sh" || rc=$?; fi; rm -f "$IP" 2>/dev/null; if [ "$rc" -eq 0 ]; then _ts="$OCN_HOME/.last_cloud_run.tmp.$$"; printf "%s\n" "$OCN_TARGET" > "$_ts" && mv -f "$_ts" "$OCN_HOME/.last_cloud_run" || { rm -f "$_ts" 2>/dev/null; printf "os-clone-nag: WARNING: backup succeeded but could not stamp .last_cloud_run\n" >&2; }; fi; exit "$rc"' \
            || { _rc=$?; rm -f "$IN_PROGRESS_FILE" 2>/dev/null; printf 'os-clone-nag: WARNING: failed to launch backup terminal (rc=%d)\n' "$_rc" >&2; printf 'os-clone-nag: WARNING: failed to launch backup terminal (rc=%d) at %s\n' "$_rc" "$(date -Iseconds)" >> "$_LOG_FILE" 2>/dev/null; }
        fi
    elif [ "$ZENITY_RC" -ne 1 ]; then
        printf 'os-clone-nag: zenity failed (rc=%d)\n' "$ZENITY_RC" >&2
        printf 'os-clone-nag: zenity failed (rc=%d) at %s\n' "$ZENITY_RC" "$(date -Iseconds)" \
            >> "$_LOG_FILE" 2>/dev/null
        flock -u 9 2>/dev/null || true
        exit 1
    fi
fi

# Release lock; leave file in place (flock on a persistent path is the
# canonical pattern; removing it creates a TOCTOU window with a
# concurrent opener).
flock -u 9 2>/dev/null || true
