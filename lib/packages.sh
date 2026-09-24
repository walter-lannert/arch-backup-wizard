#!/usr/bin/env bash
# arch-backup-wizard/lib/packages.sh — Package installation via pacman and AUR helpers

# ── Query helpers ─────────────────────────────────────────────────────────────

# Check if a package is installed (used by backup/restore modules)
pkg_is_installed() {
    [[ -n "${1:-}" ]] || return 1
    pacman -Qi "$1" &>/dev/null || return 1
    # Verify file integrity; return 1 if the package is broken
    pacman -Qkk "$1" &>/dev/null
}

# ── Shared guards ─────────────────────────────────────────────────────────────

_log_file_usable() {
    local lf="${1:-}"
    [[ -n "$lf" ]] || return 1
    [[ -d "$lf" ]] && return 1
    # Reject special files (FIFOs, sockets, devices) that would block or misbehave on >> redirect
    [[ -p "$lf" || -S "$lf" || -c "$lf" || -b "$lf" ]] && return 1
    local dir
    dir="$(dirname "$lf")"
    [[ -w "$dir" ]] || return 1
    [[ -e "$lf" && ! -w "$lf" ]] && return 1
    return 0
}

# Validate that a string is a plausible pacman package name (prevents option injection)
_validate_pkg_name() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    # pacman package names: start with alphanumeric, then alphanumeric + . _ + -
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || return 1
    return 0
}

# ── Install from official repos ───────────────────────────────────────────────

pkg_install() {
    local to_install=("$@")

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    # Validate all package names before doing any work (prevents option injection)
    local _bad_name
    for _bad_name in "${to_install[@]}"; do
        if ! _validate_pkg_name "$_bad_name"; then
            log_error "Invalid package name rejected: '$_bad_name'"
            ui_msgbox "Config Error" \
                "Invalid package name detected: '$_bad_name'
Package names must start with an alphanumeric character and contain
only letters, digits, dots, hyphens, underscores, or plus signs."
            return 1
        fi
    done

    if ! _log_file_usable "${LOG_FILE:-}"; then
        log_error "LOG_FILE is unset, a directory, or not writable; aborting"
        ui_msgbox "Config Error" "LOG_FILE is not set, is a directory, or is not writable.
Check the wizard configuration."
        return 1
    fi

    # Integrity probe: warn if any target package is in a broken/half-installed state
    local broken=()
    for p in "${to_install[@]}"; do
        if pacman -Qi "$p" &>/dev/null; then
            if ! pacman -Qkk "$p" &>/dev/null; then
                broken+=("$p")
            fi
        fi
    done
    if [[ ${#broken[@]} -gt 0 ]]; then
        log_warn "Packages in a broken state (will be skipped by --needed): ${broken[*]}"
        ui_msgbox "Warning" \
            "The following packages appear to be in a broken/half-installed state:
${broken[*]}

--needed will skip them. Consider running:
  sudo pacman -U ${broken[*]}
or manually repairing before continuing."
    fi

    # --needed is the idempotency guard: pacman skips packages already in the local DB.
    log_info "Installing via pacman: ${to_install[*]}"
    ui_infobox "Installing Packages" "Installing: ${to_install[*]}..."

    if ! run_as_user sudo -v 2>>"$LOG_FILE"; then
        log_error "sudo authentication failed; cannot proceed with pacman install"
        ui_msgbox "Privilege Error" \
            "sudo authentication failed.
Please verify your user has sudo access and try again."
        return 1
    fi
    # Re-assert immediately before the privileged call to minimise the expiry window
    if ! run_as_user sudo -n true 2>>"$LOG_FILE"; then
        log_error "sudo token expired before pacman invocation"
        ui_msgbox "Privilege Error" \
            "Your sudo session expired before the install could start.
Please re-authenticate and re-run the wizard."
        return 1
    fi
    if ! run_as_user sudo pacman -S --noconfirm --needed "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log_error "pacman install failed: ${to_install[*]}"
        ui_msgbox "Package Error" \
            "Failed to install: ${to_install[*]}\n\nCheck $LOG_FILE for details."
        return 1
    fi

    local still_broken=()
    for p in "${to_install[@]}"; do
        if pacman -Qi "$p" &>/dev/null && ! pacman -Qkk "$p" &>/dev/null; then
            still_broken+=("$p")
        fi
    done
    if [[ ${#still_broken[@]} -gt 0 ]]; then
        log_error "Packages remain broken after install: ${still_broken[*]}"
        ui_msgbox "Incomplete Install" \
            "The following packages are still in a broken state after install:
${still_broken[*]}

Run 'pacman -U ${still_broken[*]}' to force-reinstall them."
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

    if ! command -v "$DETECTED_AUR_HELPER" &>/dev/null; then
        log_error "AUR helper '$DETECTED_AUR_HELPER' is not found in PATH"
        ui_msgbox "AUR Helper Missing" \
            "The detected AUR helper '$DETECTED_AUR_HELPER' is not in PATH.
It may have been uninstalled or renamed.
Re-run detection or install the helper manually."
        return 1
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    # Validate all package names before doing any work (prevents option injection)
    local _bad_name
    for _bad_name in "${to_install[@]}"; do
        if ! _validate_pkg_name "$_bad_name"; then
            log_error "Invalid AUR package name rejected: '$_bad_name'"
            ui_msgbox "Config Error" \
                "Invalid AUR package name detected: '$_bad_name'
Package names must start with an alphanumeric character and contain
only letters, digits, dots, hyphens, underscores, or plus signs."
            return 1
        fi
    done

    if ! _log_file_usable "${LOG_FILE:-}"; then
        log_error "LOG_FILE is unset, a directory, or not writable; aborting"
        ui_msgbox "Config Error" "LOG_FILE is not set, is a directory, or is not writable.
Check the wizard configuration."
        return 1
    fi

    # Integrity probe: warn if any target package is in a broken/half-installed state
    local broken=()
    for p in "${to_install[@]}"; do
        if pacman -Qi "$p" &>/dev/null; then
            if ! pacman -Qkk "$p" &>/dev/null; then
                broken+=("$p")
            fi
        fi
    done
    if [[ ${#broken[@]} -gt 0 ]]; then
        log_warn "Packages in a broken state (will be skipped by --needed): ${broken[*]}"
        ui_msgbox "Warning" \
            "The following packages appear to be in a broken/half-installed state:
${broken[*]}

--needed will skip them. Consider running:
  sudo pacman -U ${broken[*]}
or manually repairing before continuing."
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
    # Re-assert immediately before the privileged call to minimise the expiry window
    if ! run_as_user sudo -n true 2>>"$LOG_FILE"; then
        log_error "sudo token expired before AUR helper invocation"
        ui_msgbox "Privilege Error" \
            "Your sudo session expired before the install could start.
Please re-authenticate and re-run the wizard."
        return 1
    fi
    if ! run_as_user "$DETECTED_AUR_HELPER" -S --noconfirm --needed "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log_error "AUR install failed: ${to_install[*]}"
        ui_msgbox "AUR Package Error" \
            "Failed to install: ${to_install[*]}\n\nCheck $LOG_FILE for details.\n\n
If the build failed, the helper's cache may contain partial artifacts.
You can clean them with:
  $DETECTED_AUR_HELPER -Sc
or remove the specific build directory manually, then re-run."
        return 1
    fi

    local still_broken=()
    for p in "${to_install[@]}"; do
        if pacman -Qi "$p" &>/dev/null && ! pacman -Qkk "$p" &>/dev/null; then
            still_broken+=("$p")
        fi
    done
    if [[ ${#still_broken[@]} -gt 0 ]]; then
        log_error "Packages remain broken after AUR install: ${still_broken[*]}"
        ui_msgbox "Incomplete Install" \
            "The following packages are still in a broken state after install:
${still_broken[*]}

Run '$DETECTED_AUR_HELPER -U ${still_broken[*]}' to force-reinstall them."
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
            log_info "No snapshot-integration package for bootloader: ${DETECTED_BOOTLOADER:-unknown}" >&2
            ;;
        esac
        printf '%s\n' "$pkgs"
        ;;
    2) printf '%s\n' "btrbk" ;;
    3) printf '%s\n' "pika-backup" ;;
    4) printf '%s\n' "rclone pv zstd zenity age fuse3" ;;
    5) ;; # No packages needed
    esac
}

# ── Convenience: install everything a layer needs ─────────────────────────────

install_layer_packages() {
    local layer="${1:-}"
    # Validate layer number early to avoid silent no-op on bad input
    if ! [[ "$layer" =~ ^[1-5]$ ]]; then
        log_error "install_layer_packages: invalid layer '$layer' (expected 1-5)"
        ui_msgbox "Config Error" \
            "Invalid layer number: '$layer'
Expected a value between 1 and 5."
        return 1
    fi

    local all_pkgs
    if ! all_pkgs=$(get_layer_packages "$layer"); then
        log_error "get_layer_packages failed for layer $layer"
        return 1
    fi

    local pacman_pkgs=()
    local aur_pkgs=()

    local -a pkg_list=()
    local aur_name
    [[ -n "$all_pkgs" ]] && read -ra pkg_list <<< "$all_pkgs"
    for pkg in "${pkg_list[@]}"; do
        [[ -z "$pkg" ]] && continue
        # Reject tokens that are clearly not valid package names
        local _invalid_re='[][\s/@#;|&$]'
        if [[ "$pkg" =~ $_invalid_re ]]; then
            log_error "Skipping invalid token from layer $layer: '$pkg'" >&2
            continue
        fi
        if [[ "$pkg" == AUR:* ]]; then
            aur_name="${pkg#AUR:}"
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
            return 1
        fi
        echo "Installing 'dialog' (required for the wizard UI)..."
        if ! _log_file_usable "${LOG_FILE:-}"; then
            echo "FATAL: LOG_FILE is unset, a directory, or not writable. Check the wizard configuration." >&2
            return 1
        fi
        run_as_user sudo -v 2>>"$LOG_FILE" || {
            echo "FATAL: sudo authentication failed. Verify sudo access." >&2
            return 1
        }
        run_as_user pacman -S --noconfirm --needed dialog >>"$LOG_FILE" 2>&1 || {
            echo "FATAL: Could not install 'dialog'. Install it manually: sudo pacman -S dialog" >&2
            return 1
        }
        if ! cmd_exists dialog && ! cmd_exists whiptail; then
            echo "FATAL: 'dialog' was installed but is not found in PATH. Check your PATH." >&2
            return 1
        fi
    fi
}
