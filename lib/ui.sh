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
        die $'Neither dialog nor whiptail found. Install one first:\n  sudo pacman -S dialog'
    fi
    log_info "Using dialog backend: $DIALOG_CMD"
}

# ── Default dimensions ────────────────────────────────────────────────────────
# These can be overridden per-call if needed.

DLG_H=20
DLG_W=72
DLG_LIST_H=10 # inner list height for menus/checklists

# ── Backend guard ─────────────────────────────────────────────────────────────

_ui_ensure_backend() {
    if [[ -z "$DIALOG_CMD" ]]; then
        die "UI backend not initialised. Call detect_dialog() first."
    fi
    return 0
}

# ── Primitive wrappers ────────────────────────────────────────────────────────

# Message box (OK button only)
ui_msgbox() {
    [[ "${UI_SILENT:-false}" == "true" ]] && return 0
    _ui_ensure_backend
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --msgbox "$text" $DLG_H $DLG_W || true
}

# Yes / No dialog.  Returns 0 = Yes, 1 = No.
ui_yesno() {
    [[ "${UI_SILENT:-false}" == "true" ]] && return 0
    _ui_ensure_backend
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --yesno "$text" $DLG_H $DLG_W
}

# Single-selection menu.  Returns selected tag on stdout.
# Extra args: tag1 label1 tag2 label2 …
ui_menu() {
    if [[ "${UI_SILENT:-false}" == "true" ]]; then
        echo "${3:-}"
        return 0
    fi
    _ui_ensure_backend
    local title="$1" text="$2"
    shift 2
    $DIALOG_CMD --title "$title" --menu "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Multi-selection checklist.  Returns space-separated tags on stdout.
# Extra args: tag1 label1 on/off  tag2 label2 on/off …
ui_checklist() {
    if [[ "${UI_SILENT:-false}" == "true" ]]; then
        shift 2
        local result=()
        while (( $# >= 3 )); do
            local tag="$1" state="$3"
            shift 3
            if [[ "$state" == "on" ]]; then
                result+=("\"$tag\"")
            fi
        done
        echo "${result[*]:-}"
        return 0
    fi
    _ui_ensure_backend
    local title="$1" text="$2"
    shift 2
    $DIALOG_CMD --title "$title" --checklist "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Single-selection radio list.  Returns selected tag on stdout.
# Extra args: tag1 label1 on/off  tag2 label2 on/off …
ui_radiolist() {
    if [[ "${UI_SILENT:-false}" == "true" ]]; then
        local first_tag="${3:-}"
        shift 2
        while (( $# >= 3 )); do
            local tag="$1" state="$3"
            shift 3
            if [[ "$state" == "on" ]]; then
                echo "$tag"
                return 0
            fi
        done
        echo "$first_tag"
        return 0
    fi
    _ui_ensure_backend
    local title="$1" text="$2"
    shift 2
    $DIALOG_CMD --title "$title" --radiolist "$text" \
        $DLG_H $DLG_W $DLG_LIST_H "$@" 3>&1 1>&2 2>&3
}

# Text input box.  Returns entered text on stdout.
ui_inputbox() {
    if [[ "${UI_SILENT:-false}" == "true" ]]; then
        echo "${3:-}"
        return 0
    fi
    _ui_ensure_backend
    local title="$1" text="$2" default="${3:-}"
    $DIALOG_CMD --title "$title" --inputbox "$text" \
        $DLG_H $DLG_W "$default" 3>&1 1>&2 2>&3
}

# Blocking info box (no buttons; user must press a key to dismiss)
ui_infobox() {
    [[ "${UI_SILENT:-false}" == "true" ]] && return 0
    _ui_ensure_backend
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --infobox "$text" $DLG_H $DLG_W || true
}

# ── Compound helpers ──────────────────────────────────────────────────────────

# Show a scrollable text file
ui_textbox() {
    [[ "${UI_SILENT:-false}" == "true" ]] && return 0
    _ui_ensure_backend
    local title="$1" file="$2"
    $DIALOG_CMD --title "$title" --textbox "$file" $DLG_H $DLG_W || true
}

# Confirm before a destructive action (defaults to No)
ui_confirm_destructive() {
    [[ "${UI_SILENT:-false}" == "true" ]] && return 0
    _ui_ensure_backend
    local title="$1" text="$2"
    $DIALOG_CMD --title "$title" --defaultno --yesno "$text" $DLG_H $DLG_W
}
