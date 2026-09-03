#!/usr/bin/env bash
# arch-backup-wizard/lib/packages.sh — Package installation via pacman and AUR helpers

# ── Query helpers ─────────────────────────────────────────────────────────────

# Check if a package is installed
pkg_is_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Check if a package exists in the official repos
pkg_in_repos() {
    pacman -Si "$1" &>/dev/null
}

# ── Install from official repos ───────────────────────────────────────────────

pkg_install() {
    local packages=("$@")
    local to_install=()

    for pkg in "${packages[@]}"; do
        if pkg_is_installed "$pkg"; then
            log_info "Already installed: $pkg"
        else
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Installing via pacman: ${to_install[*]}"
    ui_infobox "Installing Packages" "Installing: ${to_install[*]}..."

    if ! pacman -S --noconfirm --needed "${to_install[@]}" >> "$LOG_FILE" 2>&1; then
        log_error "pacman install failed: ${to_install[*]}"
        ui_msgbox "Package Error" \
            "Failed to install: ${to_install[*]}\n\nCheck $LOG_FILE for details."
        return 1
    fi

    log_success "Installed: ${to_install[*]}"
}

# ── Install from AUR ──────────────────────────────────────────────────────────

aur_install() {
    local packages=("$@")
    local to_install=()

    if [[ -z "${DETECTED_AUR_HELPER:-}" ]]; then
        ui_msgbox "AUR Helper Required" \
"No AUR helper (paru, yay) was detected on this system.

Please install one first:
  sudo pacman -S paru

Then re-run this wizard."
        return 1
    fi

    for pkg in "${packages[@]}"; do
        if pkg_is_installed "$pkg"; then
            log_info "Already installed (AUR): $pkg"
        else
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Installing via $DETECTED_AUR_HELPER: ${to_install[*]}"
    ui_infobox "Installing AUR Packages" \
        "Installing via $DETECTED_AUR_HELPER: ${to_install[*]}..."

    # AUR helpers must NOT be run as root
    if ! run_as_user "$DETECTED_AUR_HELPER" -S --noconfirm --needed \
            "${to_install[@]}" >> "$LOG_FILE" 2>&1; then
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
            echo "snapper snap-pac"
            case "${DETECTED_BOOTLOADER:-}" in
                grub)   echo "grub-btrfs" ;;
                limine) echo "AUR:limine-snapper-sync" ;;
                # systemd-boot has no snapshot integration package
            esac
            ;;
        2)  echo "btrbk" ;;
        3)  echo "pika-backup" ;;
        4)  echo "rclone pv zstd zenity" ;;
        5)  ;; # No packages needed
    esac
}

# ── Convenience: install everything a layer needs ─────────────────────────────

install_layer_packages() {
    local layer="$1"
    local all_pkgs
    all_pkgs=$(get_layer_packages "$layer")

    local pacman_pkgs=()
    local aur_pkgs=()

    for pkg in $all_pkgs; do
        if [[ "$pkg" == AUR:* ]]; then
            aur_pkgs+=("${pkg#AUR:}")
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
        echo "Installing 'dialog' (required for the wizard UI)..."
        pacman -S --noconfirm dialog >> "$LOG_FILE" 2>&1 || {
            echo "FATAL: Could not install 'dialog'. Install it manually: sudo pacman -S dialog" >&2
            exit 1
        }
    fi
}
