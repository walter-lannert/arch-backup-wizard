#!/usr/bin/env bash
# arch-backup-wizard/lib/uninstall.sh — Cleanly remove wizard-created configurations
#
# Provides the --uninstall functionality that removes configurations, systemd units,
# timers, and nag scripts created by the wizard across all layers.
# Preserves installed packages, user data, backup drives, recovery runbooks, and deep storage.

# ── Main uninstall entrypoint ──────────────────────────────────────────────────

run_uninstall() {
    require_root
    [[ -z "${DIALOG_CMD:-}" ]] && detect_dialog

    log_info "══════ Initiating Arch Backup Wizard Uninstall ══════"

    # ── 1. Warning & confirmation dialog ──────────────────────────────────────
    local warning_msg="This will remove all backup configurations created by the Arch Backup Wizard:

• Snapper config (/etc/snapper/configs/root)
• btrbk config (/etc/btrbk/btrbk.conf) and systemd override
• Cloud backup scripts (~/.os_cloud_backup.sh, ~/.os_clone_nag.sh)
• Pika cloud sync systemd timer
• Shell startup nag integration

This will NOT remove:
• Installed packages (snapper, btrbk, pika-backup, rclone)
• Your actual backup data
• Recovery runbooks
• Deep Storage contents"

    if ! ui_confirm_destructive "Uninstall Wizard Configurations" "$warning_msg"; then
        log_info "Uninstall aborted by user."
        exit 0
    fi

    # ── 2. Layer 1 cleanup (Snapper) ──────────────────────────────────────────
    log_info "── Layer 1 Cleanup: Snapper ──"
    log_info "Disabling snapper-cleanup.timer..."
    systemctl disable --now snapper-cleanup.timer >> "$LOG_FILE" 2>&1 || true

    local snapper_cfg="/etc/snapper/configs/root"
    if [[ -f "$snapper_cfg" ]]; then
        log_info "Removing Snapper root configuration: $snapper_cfg"
        rm -f "$snapper_cfg"
        log_success "Removed $snapper_cfg"
    else
        log_info "Snapper root configuration not found ($snapper_cfg); skipping."
    fi

    # ── 3. Layer 2 cleanup (btrbk) ────────────────────────────────────────────
    log_info "── Layer 2 Cleanup: btrbk ──"
    log_info "Disabling btrbk.timer..."
    systemctl disable --now btrbk.timer >> "$LOG_FILE" 2>&1 || true

    local btrbk_cfg="/etc/btrbk/btrbk.conf"
    if [[ -f "$btrbk_cfg" ]]; then
        log_info "Removing btrbk configuration: $btrbk_cfg"
        rm -f "$btrbk_cfg"
        log_success "Removed $btrbk_cfg"
    else
        log_info "btrbk configuration not found ($btrbk_cfg); skipping."
    fi

    local btrbk_override="/etc/systemd/system/btrbk.service.d/override.conf"
    if [[ -e "$btrbk_override" ]]; then
        log_info "Removing btrbk systemd override: $btrbk_override"
        rm -rf "$btrbk_override"
        rmdir /etc/systemd/system/btrbk.service.d 2>/dev/null || true
        log_success "Removed $btrbk_override"
    else
        log_info "btrbk systemd override not found ($btrbk_override); skipping."
    fi

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true

    # ── 4. Layer 4 cleanup (Cloud & Nag Scripts) ──────────────────────────────
    log_info "── Layer 4 Cleanup: Cloud Offsite & Nag Scripts ──"
    local user
    user=$(get_real_user)
    local home
    home=$(get_real_home)

    [[ -z "$user" ]] && user="${DETECTED_USER:-root}"
    [[ -z "$home" ]] && home="${DETECTED_HOME:-/root}"

    log_info "Target user: $user (home: $home)"

    log_info "Disabling pika-cloud-sync.timer for user $user..."
    run_as_user systemctl --user disable --now pika-cloud-sync.timer 2>/dev/null || true

    local cloud_files=(
        "$home/.os_cloud_backup.sh"
        "$home/.os_clone_nag.sh"
        "$home/.last_cloud_run"
        "$home/.config/systemd/user/pika-cloud-sync.service"
        "$home/.config/systemd/user/pika-cloud-sync.timer"
    )

    for file in "${cloud_files[@]}"; do
        if [[ -e "$file" ]]; then
            log_info "Removing $file"
            rm -f "$file"
            log_success "Removed $file"
        else
            log_info "File not found: $file (skipping)"
        fi
    done

    log_info "Reloading user systemd daemon for user $user..."
    run_as_user systemctl --user daemon-reload 2>/dev/null || true

    log_info "Removing nag script lines from shell startup files..."
    local shell_files=(
        "$home/.bashrc"
        "$home/.zshrc"
        "$home/.config/fish/config.fish"
    )

    for rc in "${shell_files[@]}"; do
        if [[ -f "$rc" ]]; then
            if grep -q "os_clone_nag" "$rc" 2>/dev/null; then
                log_info "Removing nag script lines from $rc..."
                backup_file "$rc" >/dev/null
                sed -i '/Arch Backup Wizard OS Clone Nag/d' "$rc"
                sed -i '/os_clone_nag/d' "$rc"
                chown "$user:$user" "$rc" 2>/dev/null || true
                log_success "Cleaned nag script lines from $rc"
            else
                log_info "Nag script line not found in $rc (skipping)"
            fi
        else
            log_info "Shell config not found: $rc (skipping)"
        fi
    done

    # ── 5. Success message ────────────────────────────────────────────────────
    ui_msgbox "Uninstall Complete" \
"All wizard configurations have been removed.

Packages and backup data were preserved.
You can reinstall by running the wizard again."

    # ── 6. Log completion & exit ──────────────────────────────────────────────
    log_success "══════ Wizard configuration uninstall completed successfully ══════"
    exit 0
}

export -f run_uninstall
