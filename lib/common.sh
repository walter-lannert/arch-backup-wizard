#!/usr/bin/env bash
# arch-backup-wizard/lib/common.sh — Shared utilities, logging, and helpers

[[ -n "${_ARCH_BACKUP_COMMON_LOADED:-}" ]] && return 0
_ARCH_BACKUP_COMMON_LOADED=1

# ── Colors ────────────────────────────────────────────────────────────────────
readonly CLR_RED='\033[0;31m'
readonly CLR_NC='\033[0m'

# ── Layer ID constants ────────────────────────────────────────────────────────
# Use these named constants wherever a layer is identified by number so that
# renaming or adding a layer requires changing only this block.
readonly LAYER_SNAPPER=1
readonly LAYER_BTRBK=2
readonly LAYER_PIKA=3
readonly LAYER_CLOUD=4
readonly LAYER_DEEP=5

# ── Configuration defaults ────────────────────────────────────────────────────
# All tunable defaults live here. Changing a value in this block is the single
# place required to alter wizard behaviour — no need to hunt for literals.

# btrbk (Layer 2) retention policy
readonly BTRBK_SNAP_MIN="7d"       # minimum local snapshot age to keep
readonly BTRBK_SNAP="14d"          # local snapshot retention window
readonly BTRBK_TARGET_MIN="latest" # minimum target (backup drive) retention
readonly BTRBK_TARGET="14d"        # target retention window

# Snapshot directory paths
readonly SNAP_DIR="/.snapshots"             # Snapper snapshot mount (Layer 1)
readonly SNAP_DIR_BTRBK="/.snapshots_btrbk" # btrbk snapshot dir (Layer 2)

# btrbk configuration paths
readonly BTRBK_CONF="/etc/btrbk/btrbk.conf"
readonly BTRBK_OVERRIDE_DIR="/etc/systemd/system/btrbk.service.d"

# ── Global contract ─────────────────────────────────────────────────────────
# The wizard operates by setting global variables in detect.sh or wizard.sh
# which are then consumed by the layer scripts (lib/*.sh).
#
# BACKUP_MOUNT          – set by wizard.sh; consumed by layer2..5, runbooks, validate
# BACKUP_UUID           – set by detect.sh/wizard.sh; consumed by validate
# SELECTED_LAYERS       – set by wizard.sh; consumed by runbooks, validate, packages
# DETECTED_*            – set by detect.sh; consumed across all modules
# WIZARD_DIR            – set by wizard.sh; used for relative paths in all modules
# ────────────────────────────────────────────────────────────────────────────

# SELECTED_LAYERS holds the IDs chosen by the user (or set by --validate).
# Declared here so that set -u never trips when layer_selected is called
# before wizard.sh has had a chance to populate it.
SELECTED_LAYERS=("${SELECTED_LAYERS[@]+"${SELECTED_LAYERS[@]}"}")

# Returns 0 if the given layer ID was selected, 1 otherwise.
# This is the single authoritative definition — do NOT redefine it in
# lib/runbooks.sh or lib/validate.sh.
layer_selected() {
    local target="$1"
    local l
    for l in "${SELECTED_LAYERS[@]+"${SELECTED_LAYERS[@]}"}"; do
        [[ "$l" == "$target" ]] && return 0
    done
    return 1
}

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="${LOG_FILE:-/tmp/arch-backup-wizard.log}"

_log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%-5s] %s\n' "$timestamp" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || \
    printf '[%s] [%-5s] %s\n' "$timestamp" "$level" "$*" >>"/tmp/arch-backup-wizard.log" 2>/dev/null || true
}

log_info() { _log "INFO" "$*"; }
log_warn() { _log "WARN" "$*"; }
log_error() { _log "ERROR" "$*"; }
log_success() { _log "OK" "$*"; }
log_debug() { _log "DEBUG" "$*"; }

# Fatal error — log, print to stderr, and exit immediately.
#
# USAGE CONTRACT:
#   die() is ONLY for unrecoverable precondition failures in wizard.sh:
#     - not running as root
#     - root filesystem is not BTRFS
#     - no backup drive selected
#   It must NOT be called from inside setup_layerN() or any lib/ module.
#   Layer-level failures must use:  log_error "..."; return 1
#   This ensures the wizard always reaches runbook generation and validation
#   even if an individual layer fails.
die() {
    log_error "$*"
    echo -e "${CLR_RED}FATAL: $*${CLR_NC}" >&2
    exit 1
}

# ── File helpers ──────────────────────────────────────────────────────────────
MANIFEST_FILE="${MANIFEST_FILE:-/var/lib/arch-backup-wizard/manifest.txt}"

# Record a file created by the wizard for uninstallation
record_manifest() {
    local file="$1"
    mkdir -p "$(dirname "$MANIFEST_FILE")"
    if ! grep -Fxq "$file" "$MANIFEST_FILE" 2>/dev/null; then
        echo "$file" >> "$MANIFEST_FILE"
    fi
}

ORIG_MANIFEST="${ORIG_MANIFEST:-/var/lib/arch-backup-wizard/unmanaged_orig.txt}"

# Back up a file before modifying it (timestamped .bak copy)
# Prompts for confirmation if the file already exists but is NOT tracked in the manifest
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local is_shared=false
        case "$file" in
            /etc/fstab|*/.bashrc|*/.zshrc|*/config.fish) is_shared=true ;;
        esac

        if [[ ! -f "$MANIFEST_FILE" ]] || ! grep -Fxq "$file" "$MANIFEST_FILE" 2>/dev/null; then
            mkdir -p "$(dirname "$ORIG_MANIFEST")"
            if ! grep -Fxq "$file" "$ORIG_MANIFEST" 2>/dev/null; then
                echo "$file" >> "$ORIG_MANIFEST"
            fi

            if ! ${UNINSTALL:-false} && ! $is_shared; then
                if ! ui_yesno "Overwrite Existing Configuration?" \
                    "The file '$file' already exists and was not created by the wizard.

Overwriting it may destroy your custom settings (a backup will be saved).
Do you want to proceed and overwrite it?"; then
                    log_warn "User aborted overwrite of unmanaged file: $file"
                    return 1
                fi
            fi
        fi

        local backup
        backup="${file}.bak.$(date +%s).$$"
        cp -p "$file" "$backup"
        log_info "Backed up $file → $backup"
    fi
}

# Render a template file: replaces every {{KEY}} with the value of $KEY
# Usage: template_render templates/foo.conf /etc/foo.conf
template_render() {
    local template="$1"
    local _patsub_was_set
    _patsub_was_set=$(shopt -p patsub_replacement 2>/dev/null) || _patsub_was_set=""
    shopt -u patsub_replacement 2>/dev/null || true
    local output="$2"
    local content
    if [[ ! -f "$template" ]]; then
        log_error "Template not found: $template"
        return 1
    fi
    content=$(<"$template")

    # Extract unique variable names from {{…}} placeholders
    local vars
    if ! vars=$(grep -oP '\{\{\K[A-Z_0-9]+(?=\}\})' <<<"$content" | sort -u) 2>/dev/null; then
        log_error "grep -P unavailable; cannot extract placeholders from $(basename "$template")"
        return 1
    fi

    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        local value="${!var:-}"

        if [[ "$output" == *.sh ]]; then
            # For shell scripts, escape the value to be safely injected inside double quotes
            # We escape \, $, `, and " so they are treated as literal characters inside "..."
            value="${value//\\/\\\\}"
            value="${value//\$/\\\$}"
            value="${value//\`/\\\`}"
            value="${value//\"/\\\"}"
        elif [[ "$output" == *.service || "$output" == *.timer || "$output" == *.conf ]]; then
            # For systemd or configuration files, prevent breaking out of double quotes
            value="${value//\"/\\\"}"
        fi

        content="${content//\{\{${var}\}\}/${value}}"
    done <<<"$vars"

    local temp_file
    local out_dir
    out_dir="$(dirname "$output")"
    temp_file=$(mktemp "${out_dir}/.template.XXXXXX") || {
        log_error "Cannot create temp file in $out_dir"
        return 1
    }
    printf "%s\n" "$content" >"$temp_file"
    chmod 644 "$temp_file"
    mv -T "$temp_file" "$output"
    log_info "Rendered template $(basename "$template") → $output"

    if [[ -n "$_patsub_was_set" ]]; then
        eval "$_patsub_was_set" 2>/dev/null || true
    fi
}

# ── User / privilege helpers ──────────────────────────────────────────────────

# Check we are running as root (or running in dry-run mode)
require_root() {
    if [[ $EUID -ne 0 ]]; then
        if ${DRY_RUN:-false} || ${VALIDATE:-false}; then
            log_warn "Running without root privileges."
            return 0
        fi
        die "This wizard must be run as root. Use: sudo $0"
    fi
}

# Get the real (non-root) user who invoked sudo
get_real_user() {
    echo "${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
}

# Canonical user/home resolution for layer modules.
# Prefers DETECTED_USER / DETECTED_HOME (set by detect.sh after run_detection),
# falling back to the get_real_* helpers. Use these instead of spelling out the
# fallback idiom inline at each call site.
effective_user() {
    echo "${DETECTED_USER:-$(get_real_user)}"
}
effective_home() {
    echo "${DETECTED_HOME:-$(getent passwd "$(effective_user)" | cut -d: -f6 2>/dev/null || echo "${HOME:-/root}")}"
}

# Run a command as the real (non-root) user
run_as_user() {
    if [[ $EUID -eq 0 ]]; then
        sudo -u "$(effective_user)" "$@"
    else
        "$@"
    fi
}

# ── Misc helpers ──────────────────────────────────────────────────────────────

# Check if a command exists on $PATH
cmd_exists() {
    command -v "$1" &>/dev/null
}

# Check if a systemd unit is active (running)
unit_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Check if a systemd unit is enabled
unit_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Ensure /var/lib/pika-cloud-sync/ exists with the enabled sentinel.
# Called by layer4_cloud.sh before installing the timer unit.
ensure_pika_sync_state() {
    local dir="/var/lib/pika-cloud-sync"
    mkdir -p "$dir" || {
        log_error "Failed to create $dir"
        return 1
    }
    touch "$dir/enabled" || {
        log_error "Failed to create $dir/enabled"
        return 1
    }
    record_manifest "$dir/enabled"
    log_info "Ensured $dir/enabled exists."
}
