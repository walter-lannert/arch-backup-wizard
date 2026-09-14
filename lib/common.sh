#!/usr/bin/env bash
# arch-backup-wizard/lib/common.sh — Shared utilities, logging, and helpers

[[ -n "${_ARCH_BACKUP_COMMON_LOADED:-}" ]] && return 0
_ARCH_BACKUP_COMMON_LOADED=1

# ── Colors ────────────────────────────────────────────────────────────────────
readonly CLR_RED='\033[0;31m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_YELLOW='\033[0;33m'
readonly CLR_BLUE='\033[0;34m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_BOLD='\033[1m'
readonly CLR_NC='\033[0m'

# ── Layer ID constants ────────────────────────────────────────────────────────
# Use these named constants wherever a layer is identified by number so that
# renaming or adding a layer requires changing only this block.
readonly LAYER_SNAPPER=1
readonly LAYER_BTRBK=2
readonly LAYER_PIKA=3
readonly LAYER_CLOUD=4
readonly LAYER_DEEP=5

# Human-readable name for a layer ID (1..5 → string label).
layer_name() {
    case "$1" in
    1) echo "Snapper" ;;
    2) echo "btrbk" ;;
    3) echo "Pika Backup" ;;
    4) echo "Cloud Offsite" ;;
    5) echo "Deep Storage" ;;
    *) echo "Layer $1" ;;
    esac
}

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
    printf '[%s] [%-5s] %s\n' "$timestamp" "$level" "$*" >>"$LOG_FILE"
}

log_info() { _log "INFO" "$*"; }
log_warn() { _log "WARN" "$*"; }
log_error() { _log "ERROR" "$*"; }
log_success() { _log "OK" "$*"; }

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

# Back up a file before modifying it (timestamped .bak copy)
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup
        backup="${file}.bak.$(date +%s)"
        cp "$file" "$backup"
        log_info "Backed up $file → $backup"
        echo "$backup"
    fi
}

# Render a template file: replaces every {{KEY}} with the value of $KEY
# Usage: template_render templates/foo.conf /etc/foo.conf
template_render() {
    local template="$1"
    local output="$2"
    local content
    content=$(<"$template")

    # Extract unique variable names from {{…}} placeholders
    local vars
    vars=$(grep -oP '\{\{\K[A-Z_0-9]+(?=\}\})' <<<"$content" | sort -u) || true

    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        local value="${!var:-}"
        content="${content//\{\{${var}\}\}/${value}}"
    done <<<"$vars"

    echo "$content" >"$output"
    log_info "Rendered template $(basename "$template") → $output"
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

# Get the real user's home directory
get_real_home() {
    getent passwd "$(effective_user)" | cut -d: -f6
}

# Canonical user/home resolution for layer modules.
# Prefers DETECTED_USER / DETECTED_HOME (set by detect.sh after run_detection),
# falling back to the get_real_* helpers. Use these instead of spelling out the
# fallback idiom inline at each call site.
effective_user() {
    echo "${DETECTED_USER:-$(get_real_user)}"
}
effective_home() {
    echo "${DETECTED_HOME:-$(get_real_home 2>/dev/null || echo "${HOME:-/root}")}"
}

# Run a command as the real (non-root) user
run_as_user() {
    sudo -u "$(effective_user)" "$@"
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
