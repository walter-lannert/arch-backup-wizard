#!/usr/bin/env bash
# arch-backup-wizard/lib/common.sh — Shared utilities, logging, and helpers

[[ -n "${_ARCH_BACKUP_COMMON_LOADED:-}" ]] && return 0
_ARCH_BACKUP_COMMON_LOADED=1

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
readonly CLR_RED='\033[0;31m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_YELLOW='\033[0;33m'
readonly CLR_BLUE='\033[0;34m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_BOLD='\033[1m'
readonly CLR_NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="${LOG_FILE:-/tmp/arch-backup-wizard.log}"

_log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%-5s] %s\n' "$timestamp" "$level" "$*" >> "$LOG_FILE"
}

log_info()    { _log "INFO"  "$*"; }
log_warn()    { _log "WARN"  "$*"; }
log_error()   { _log "ERROR" "$*"; }
log_success() { _log "OK"    "$*"; }

# Fatal error — log, print to stderr, and exit
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
        local backup="${file}.bak.$(date +%s)"
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
    vars=$(grep -oP '\{\{\K[A-Z_0-9]+(?=\}\})' <<< "$content" | sort -u) || true

    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        local value="${!var:-}"
        content="${content//\{\{${var}\}\}/${value}}"
    done <<< "$vars"

    echo "$content" > "$output"
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
    getent passwd "$(get_real_user)" | cut -d: -f6
}

# Run a command as the real (non-root) user
run_as_user() {
    sudo -u "$(get_real_user)" "$@"
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

# Check if a systemd user unit is enabled (runs as the real user)
user_unit_is_enabled() {
    sudo -u "$(get_real_user)" systemctl --user is-enabled --quiet "$1" 2>/dev/null
}
