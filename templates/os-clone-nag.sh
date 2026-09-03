#!/bin/bash

# Only run if inside a graphical desktop session
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exit 0
fi

# Ensure zenity is available
if ! command -v zenity >/dev/null 2>&1; then
    exit 0
fi

# Prevent multiple stacked prompts if multiple terminals are launched simultaneously
if pgrep -f "zenity.*OS Cloud Backup Due" >/dev/null 2>&1; then
    exit 0
fi

YEAR=$(date +%Y)
MONTH=$(date +%m)
DAY=$(date +%d)

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
    
    if zenity --question --title="OS Cloud Backup Due" \
              --text="Your bi-weekly OS clone cloud backup is due.\n\nWould you like to run it now?" \
              --ok-label="Run Now" \
              --cancel-label="Later"; then
        
        {{DETECTED_TERMINAL_CMD}} bash -c "{{DETECTED_HOME}}/.os_cloud_backup.sh && echo \"$CURRENT_TARGET\" > \"$LAST_RUN_FILE\""
    fi
fi
