#!/usr/bin/env bash
# arch-backup-wizard/lib/packages.sh — Package installation via pacman and AUR helpers

# ── Query helpers ─────────────────────────────────────────────────────────────

# Check if a package is installed
pkg_is_installed() {
    [[ -n "${1:-}" ]] || return 1
    pacman -Qi "$1" &>/dev/null
}

# ── Install from official repos ───────────────────────────────────────────────

pkg_install() {
    local to_install=("$@")

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ -z "${LOG_FILE:-}" || ! -w "$(dirname "${LOG_FILE:-/dev/null}")" \
          || ( -e "${LOG_FILE}" && ! -w "${LOG_FILE}" ) ]]; then
        log_error "LOG_FILE is unset or not writable; aborting install"
        ui_msgbox "Config Error" "LOG_FILE is not set or not writable.
Check the wizard configuration."
        return 1
    fi

    # --needed is the idempotency guard: pacman skips packages already in the local DB.
    log_info "Installing via pacman: ${to_install[*]}"
    ui_infobox "Installing Packages" "Installing: ${to_install[*]}..."

    if ! pacman -S --noconfirm --needed "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log_error "pacman install failed: ${to_install[*]}"
        ui_msgbox "Package Error" \
            "Failed to install: ${to_install[*]}\n\nCheck $LOG_FILE for details."
        return 1
    fi

    log_success "Installed: ${to_install[*]}"
}

# ── Install from AUR ──────────────────────────────────────────────────────────

aur_install() {
    local to_install=("$@")

    if [[ -z "${DETECTED_AUR_HELPER:-}" ]]; then
        ui_msgbox "AUR Helper Required" \
            "No AUR helper (paru or yay) was detected on this system.

Please install one from the AUR (or your distribution's repository) first:
  git clone https://aur.archlinux.org/paru-bin.git
  cd paru-bin && makepkg -si

Then re-run this wizard."
        return 1
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ -z "${LOG_FILE:-}" || ! -w "$(dirname "${LOG_FILE:-/dev/null}")" \
          || ( -e "${LOG_FILE}" && ! -w "${LOG_FILE}" ) ]]; then
        log_error "LOG_FILE is unset or not writable; aborting install"
        ui_msgbox "Config Error" "LOG_FILE is not set or not writable.
Check the wizard configuration."
        return 1
    fi

    log_info "Installing via $DETECTED_AUR_HELPER: ${to_install[*]}"
    ui_infobox "Installing AUR Packages" \
        "Installing via $DETECTED_AUR_HELPER: ${to_install[*]}..."

    # Ensure the user has an active sudo token to prevent hidden prompts during UI execution
    if ! run_as_user sudo -v 2>>"$LOG_FILE"; then
        log_error "sudo authentication failed; cannot proceed with AUR install"
        ui_msgbox "Privilege Error" \
            "sudo authentication failed.
Please verify your user has sudo access and try again."
        return 1
    fi
    if ! run_as_user "$DETECTED_AUR_HELPER" -S --noconfirm --needed "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log_error "AUR install failed: ${to_install[*]}"
        ui_msgbox "AUR Package Error" \
            "Failed to install: ${to_install[*]}\n\nCheck $LOG_FILE for details."
        return 1
    fi

    log_success "Installed from AUR: ${to_install[*]}"
}

# ── Per-layer package lists ───────────────────────────────────────────────────

# Returns space-separated package names.
# Prefixes AUR-only packages with "AUR:" so the caller can route them.
get_layer_packages() {
    local layer="$1"

    case "$layer" in
    1)
        local pkgs="snapper snap-pac"
        case "${DETECTED_BOOTLOADER:-}" in
        grub)   pkgs+=" AUR:grub-btrfs inotify-tools" ;;
        limine) pkgs+=" AUR:limine-snapper-sync inotify-tools" ;;
        systemd-boot) ;;  # no snapshot-integration package available
        *)
            log_info "No snapshot-integration package for bootloader: ${DETECTED_BOOTLOADER:-unknown}"
            ;;
        esac
        echo "$pkgs"
        ;;
    2) echo "btrbk" ;;
    3) echo "pika-backup" ;;
    4) echo "rclone pv zstd zenity age fuse3" ;;
    5) ;; # No packages needed
    esac
}

# ── Convenience: install everything a layer needs ─────────────────────────────

install_layer_packages() {
    local layer="$1"
    local all_pkgs
    all_pkgs=$(get_layer_packages "$layer")

    local pacman_pkgs=()
    local aur_pkgs=()

    local -a pkg_list=()
    [[ -n "$all_pkgs" ]] && read -ra pkg_list <<< "$all_pkgs"
    for pkg in "${pkg_list[@]}"; do
        [[ -z "$pkg" ]] && continue
        if [[ "$pkg" == AUR:* ]]; then
            local aur_name="${pkg#AUR:}"
            [[ -n "$aur_name" ]] || { log_error "Empty AUR package name in layer $layer"; return 1; }
            aur_pkgs+=("$aur_name")
        else
            pacman_pkgs+=("$pkg")
        fi
    done

    if [[ ${#pacman_pkgs[@]} -gt 0 ]]; then
        pkg_install "${pacman_pkgs[@]}" || return 1
    fi

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        aur_install "${aur_pkgs[@]}" || return 1
    fi

    return 0
}

# ── Ensure dialog itself is present ──────────────────────────────────────────

ensure_dialog() {
    if ! cmd_exists dialog && ! cmd_exists whiptail; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "FATAL: 'dialog' or 'whiptail' is required for the wizard UI. Since --dry-run is active, it will not be installed automatically. Please install it manually: sudo pacman -S dialog" >&2
            exit 1
        fi
        echo "Installing 'dialog' (required for the wizard UI)..."
        if [[ -z "${LOG_FILE:-}" || ! -w "$(dirname "${LOG_FILE:-/dev/null}")" \
              || ( -e "${LOG_FILE}" && ! -w "${LOG_FILE}" ) ]]; then
            echo "FATAL: LOG_FILE is unset or not writable. Check the wizard configuration." >&2
            exit 1
        fi
        pacman -S --noconfirm --needed dialog >>"$LOG_FILE" 2>&1 || {
            echo "FATAL: Could not install 'dialog'. Install it manually: sudo pacman -S dialog" >&2
            exit 1
        }
    fi
}
