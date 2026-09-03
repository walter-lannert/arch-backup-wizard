#!/usr/bin/env bash
# arch-backup-wizard/lib/ui.sh — dialog/whiptail wrapper functions
#
# All UI functions use a consistent interface so the rest of the wizard
# never calls dialog/whiptail directly.

# ── Backend detection ─────────────────────────────────────────────────────────

DIALOG_CMD=""

detect_dialog() {
    if cmd_exists dialog; then
        DIALOG_CMD="dialog"
    elif cmd_exists whiptail; then
        DIALOG_CMD="whiptail"
    else
        die "Neither 'dialog' nor 'whiptail' found. Install one first:\n  sudo pacman -S dialog"
    fi
    log_info "Using dialog backend: $DIALOG_CMD"
}

# ── Default dimensions ────────────────────────────────────────────────────────
# These can be overridden per-call if needed.

DLG_H=20
DLG_W=72
DLG_LIST_H=10   # inner list height for menus/checklists

# ── Primitive wrappers ────────────────────────────────────────────────────────

# Message box (OK button only)
ui_msgbox() {
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --msgbox "$text" $DLG_H $DLG_W
}

# Yes / No dialog.  Returns 0 = Yes, 1 = No.
ui_yesno() {
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --yesno "$text" $DLG_H $DLG_W
}

# Single-selection menu.  Returns selected tag on stdout.
# Extra args: tag1 label1 tag2 label2 …
ui_menu() {
    local title="$1" text="$2"; shift 2
    $DIALOG_CMD --title "$title" --menu "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Multi-selection checklist.  Returns space-separated tags on stdout.
# Extra args: tag1 label1 on/off  tag2 label2 on/off …
ui_checklist() {
    local title="$1" text="$2"; shift 2
    $DIALOG_CMD --title "$title" --checklist "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Single-selection radio list.  Returns selected tag on stdout.
# Extra args: tag1 label1 on/off  tag2 label2 on/off …
ui_radiolist() {
    local title="$1" text="$2"; shift 2
    $DIALOG_CMD --title "$title" --radiolist "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Text input box.  Returns entered text on stdout.
ui_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    $DIALOG_CMD --title "$title" --inputbox "$text" \
        $DLG_H $DLG_W "$default" 3>&1 1>&2 2>&3
}

# Non-blocking info box (displays, returns immediately)
ui_infobox() {
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --infobox "$text" 8 $DLG_W
}

# Progress gauge.  Reads percentage from stdin.
# Usage:  (for i in 10 50 100; do echo $i; sleep 1; done) | ui_gauge "Title" "Working..."
ui_gauge() {
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --gauge "$text" 8 $DLG_W 0
}

# ── Compound helpers ──────────────────────────────────────────────────────────

# Show a scrollable text file
ui_textbox() {
    local title="$1" file="$2"
    $DIALOG_CMD --title "$title" --textbox "$file" $DLG_H $DLG_W
}

# Confirm before a destructive action (defaults to No)
ui_confirm_destructive() {
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --defaultno --yesno "$text" $DLG_H $DLG_W
}

# Show a brief "working" message, run a command, then dismiss
# Usage: ui_run_with_status "Installing packages..." pacman -S --noconfirm snapper
ui_run_with_status() {
    local msg="$1"; shift
    ui_infobox "Working" "$msg"
    "$@" >> "$LOG_FILE" 2>&1
}
