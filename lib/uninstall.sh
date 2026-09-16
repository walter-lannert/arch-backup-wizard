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
• btrbk config ($BTRBK_CONF) and systemd override
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
    log_info "── System Service Cleanup ──"
    log_info "Disabling snapper-cleanup.timer..."
    systemctl disable --now snapper-cleanup.timer >>"$LOG_FILE" 2>&1 || true

    log_info "Disabling btrbk.timer..."
    systemctl disable --now btrbk.timer >>"$LOG_FILE" 2>&1 || true

    log_info "Disabling bootloader snapshot integrations if active..."
    systemctl disable --now grub-btrfsd >>"$LOG_FILE" 2>&1 || true
    systemctl disable --now limine-snapper-sync >>"$LOG_FILE" 2>&1 || true

    log_info "Disabling pika-cloud-sync.timer..."
    systemctl disable --now pika-cloud-sync.timer >>"$LOG_FILE" 2>&1 || true

    if [[ -f /etc/conf.d/snapper ]]; then
        sed -i 's/\bSNAPPER_CONFIGS="root\b/SNAPPER_CONFIGS="/g; s/\bSNAPPER_CONFIGS="\(.*\) root\b/SNAPPER_CONFIGS="\1/g; s/\bSNAPPER_CONFIGS="root \([^"]*\)"/SNAPPER_CONFIGS="\1"/g' /etc/conf.d/snapper
    fi

    if grep -q '# BEGIN Arch Backup Wizard Mount' /etc/fstab 2>/dev/null || grep -q '# Arch Backup Wizard Mount' /etc/fstab 2>/dev/null; then
        # Handle legacy uninstalls and new BEGIN/END tags
        sed -i -z 's/\n# Arch Backup Wizard Mount\n[^\n]*\n//g' /etc/fstab 2>/dev/null || true
        sed -i '/# BEGIN Arch Backup Wizard Mount/,/# END Arch Backup Wizard Mount/d' /etc/fstab 2>/dev/null || true
        log_info "Removed managed entry from /etc/fstab"
    fi

    local manifest_file="/var/lib/arch-backup-wizard/manifest.txt"
    if [[ ! -f "$manifest_file" ]]; then
        log_warn "Manifest file not found at $manifest_file. No generated files to remove."
    else
        log_info "Reading manifest file: $manifest_file"
        while IFS= read -r file; do
            if [[ -e "$file" ]]; then
                log_info "Removing $file"
                if btrfs subvolume show "$file" &>/dev/null; then
                    # Before deleting, check if this is the Snapper config
                    if [[ "$file" == "/.snapshots" ]] && cmd_exists snapper; then
                        snapper -c root delete-config >>"$LOG_FILE" 2>&1 || true
                    fi
                    # Audit-040: Only delete subvolumes if they are empty to protect user data
                    # Btrfs fails to delete if there are nested subvolumes, but checking explicitly is safer
                    if ! btrfs subvolume list -o "$file" 2>/dev/null | grep -q .; then
                        btrfs subvolume delete "$file" >>"$LOG_FILE" 2>&1 || true
                    else
                        log_warn "Subvolume $file contains nested subvolumes (e.g., user snapshots). Skipping deletion to prevent data loss."
                    fi
                elif [[ -d "$file" ]]; then
                    rmdir "$file" 2>/dev/null || true
                else
                    rm -f "$file"
                    local latest_bak
                    # shellcheck disable=SC2012
                    latest_bak=$(ls -1d "${file}.bak."* 2>/dev/null | sort -r | head -n 1 || true)
                    if [[ -n "$latest_bak" && -f "$latest_bak" ]]; then
                        mv "$latest_bak" "$file"
                        log_info "Restored previous state of $file from backup"
                    fi
                fi
                
                # Clean up empty parent directories like /etc/systemd/system/btrbk.service.d
                local parent_dir
                parent_dir=$(dirname "$file")
                if [[ -d "$parent_dir" ]]; then
                    rmdir "$parent_dir" 2>/dev/null || true
                fi
            else
                log_info "File not found: $file (skipping)"
            fi
        done < "$manifest_file"
        rm -f "$manifest_file"
    fi

    local user
    user="$(effective_user)"
    local target_uid; target_uid=$(id -u "$user")
    local home
    home="$(effective_home)"

    # Also clean up any lingering local archives from interrupted backups
    if [[ -n "${BACKUP_MOUNT:-}" && -d "${BACKUP_MOUNT}/Personal" ]]; then
        rm -f "${BACKUP_MOUNT}/Personal/Cloud_Archive.btrfs.zst" 2>/dev/null || true
        rm -f "${BACKUP_MOUNT}/Personal/Cloud_Archive.btrfs.zst.age" 2>/dev/null || true
        rm -f "${BACKUP_MOUNT}/Personal/"*.btrfs.zst.age 2>/dev/null || true
    fi

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    log_info "Reloading user systemd daemon for user $user..."
    run_as_user env XDG_RUNTIME_DIR="/run/user/$target_uid" systemctl --user daemon-reload 2>/dev/null || true

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
                backup_file "$rc" >/dev/null || continue
                run_as_user sed -i \
                    -e '/# Arch Backup Wizard OS Clone Nag BEGIN/,/# Arch Backup Wizard OS Clone Nag END/d' \
                    -e '/# Arch Backup Wizard OS Clone Nag/d' \
                    "$rc"
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
