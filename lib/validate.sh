#!/usr/bin/env bash
# arch-backup-wizard/lib/validate.sh — Post-setup health checks and validation dashboard
#
# Runs comprehensive verification across all configured backup layers,
# cross-layer configurations (fstab, recovery runbooks), and displays
# a health summary dashboard via dialog.

# ── Main validation entrypoint ────────────────────────────────────────────────

run_validation() {
    log_info "══════ Starting Post-Setup Validation Checks ══════"

    # Ensure dialog backend is ready
    if [[ -z "${DIALOG_CMD:-}" ]]; then
        if declare -F detect_dialog >/dev/null 2>&1; then
            detect_dialog
        elif command -v dialog &>/dev/null; then
            DIALOG_CMD="dialog"
        elif command -v whiptail &>/dev/null; then
            DIALOG_CMD="whiptail"
        fi
    fi

    local all_passed=true
    local failure_issues=()
    local user_home
    user_home="$(effective_home)"

    # ── 1. Check Layer 1 (Snapper) ────────────────────────────────────────────
    local layer1_status="— Skipped"
    if layer_selected "$LAYER_SNAPPER"; then
        log_info "Validating Layer 1 (Snapper)..."
        local l1_ok=true

        if ! pkg_is_installed snapper; then
            l1_ok=false
            log_warn "Layer 1 check failed: package 'snapper' is not installed"
            failure_issues+=("Layer 1: snapper package not installed")
        fi

        if [[ ! -f /etc/snapper/configs/root ]]; then
            l1_ok=false
            log_warn "Layer 1 check failed: /etc/snapper/configs/root does not exist"
            failure_issues+=("Layer 1: /etc/snapper/configs/root missing")
        fi

        if [[ ! -f /usr/share/libalpm/hooks/05-snap-pac-pre.hook || ! -f /usr/share/libalpm/hooks/zz-snap-pac-post.hook ]]; then
            l1_ok=false
            log_warn "Layer 1 check failed: snap-pac hooks (/usr/share/libalpm/hooks/05-snap-pac-pre.hook or zz-snap-pac-post.hook) do not exist"
            failure_issues+=("Layer 1: snap-pac hooks missing")
        fi

        # 'snapper list' requires root privileges
        local snapper_accessible=false
        if [[ $EUID -eq 0 ]]; then
            snapper list &>/dev/null && snapper_accessible=true
        else
            if sudo -n snapper list &>/dev/null; then
                snapper_accessible=true
            fi
        fi

        if ! $snapper_accessible; then
            if [[ $EUID -ne 0 ]]; then
                log_info "Layer 1 note: 'snapper list' requires root privileges; skipping command execution check in non-root dry-run"
            else
                l1_ok=false
                log_warn "Layer 1 check failed: 'snapper list' exited with non-zero status"
                failure_issues+=("Layer 1: 'snapper list' command failed")
            fi
        fi

        if ! unit_is_enabled snapper-cleanup.timer; then
            l1_ok=false
            log_warn "Layer 1 check failed: snapper-cleanup.timer is not enabled"
            failure_issues+=("Layer 1: snapper-cleanup.timer not enabled")
        fi

        if ! unit_is_active snapper-cleanup.timer; then
            l1_ok=false
            log_warn "Layer 1 check failed: snapper-cleanup.timer is not active (running)"
            failure_issues+=("Layer 1: snapper-cleanup.timer not active")
        fi

        case "${DETECTED_BOOTLOADER:-}" in
        grub)
            if ! unit_is_enabled grub-btrfsd; then
                l1_ok=false
                log_warn "Layer 1 check failed: grub-btrfsd is not enabled"
                failure_issues+=("Layer 1: grub-btrfsd not enabled")
            fi
            ;;
        limine)
            if ! unit_is_enabled limine-snapper-sync; then
                l1_ok=false
                log_warn "Layer 1 check failed: limine-snapper-sync is not enabled"
                failure_issues+=("Layer 1: limine-snapper-sync not enabled")
            fi
            ;;
        esac

        if $l1_ok; then
            layer1_status="✓ OK"
            log_success "Layer 1 (Snapper): All checks passed"
        else
            layer1_status="✗ ISSUES"
            all_passed=false
            log_error "Layer 1 (Snapper): Verification failed"
        fi
    else
        log_info "Layer 1 (Snapper): Skipped (not selected)"
    fi

    # ── 2. Check Layer 2 (btrbk) ──────────────────────────────────────────────
    local layer2_status="— Skipped"
    if layer_selected "$LAYER_BTRBK"; then
        log_info "Validating Layer 2 (btrbk)..."
        local l2_ok=true

        if ! pkg_is_installed btrbk; then
            l2_ok=false
            log_warn "Layer 2 check failed: package 'btrbk' is not installed"
            failure_issues+=("Layer 2: btrbk package not installed")
        fi

        if [[ ! -f "$BTRBK_CONF" ]]; then
            l2_ok=false
            log_warn "Layer 2 check failed: $BTRBK_CONF does not exist"
            failure_issues+=("Layer 2: $BTRBK_CONF missing")
        fi

        if ! unit_is_enabled btrbk.timer; then
            l2_ok=false
            log_warn "Layer 2 check failed: btrbk.timer is not enabled"
            failure_issues+=("Layer 2: btrbk.timer not enabled")
        fi

        if ! unit_is_active btrbk.timer; then
            l2_ok=false
            log_warn "Layer 2 check failed: btrbk.timer is not active (running)"
            failure_issues+=("Layer 2: btrbk.timer not active")
        fi

        if [[ -z "${BACKUP_MOUNT:-}" || ! -d "${BACKUP_MOUNT}/OS_Backup" ]]; then
            l2_ok=false
            log_warn "Layer 2 check failed: directory '${BACKUP_MOUNT:-}/OS_Backup' does not exist"
            failure_issues+=("Layer 2: ${BACKUP_MOUNT:-}/OS_Backup directory missing")
        fi

        if $l2_ok; then
            if [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null; then
                # shellcheck disable=SC2024
                if ! sudo -n btrbk -c "$BTRBK_CONF" dryrun >>"$LOG_FILE" 2>&1; then
                    l2_ok=false
                    log_warn "Layer 2 check failed: btrbk.conf failed to parse or dryrun"
                    failure_issues+=("Layer 2: btrbk configuration invalid (fails dryrun)")
                fi
            else
                log_info "Layer 2: Skipping btrbk dryrun (requires root privileges)"
            fi
        fi

        if $l2_ok; then
            layer2_status="✓ OK"
            log_success "Layer 2 (btrbk): All checks passed"
        else
            layer2_status="✗ ISSUES"
            all_passed=false
            log_error "Layer 2 (btrbk): Verification failed"
        fi
    else
        log_info "Layer 2 (btrbk): Skipped (not selected)"
    fi

    # ── 3. Check Layer 3 (Pika Backup) ────────────────────────────────────────
    local layer3_status="— Skipped"
    if layer_selected "$LAYER_PIKA"; then
        log_info "Validating Layer 3 (Pika Backup)..."
        local l3_ok=true

        if ! pkg_is_installed pika-backup; then
            l3_ok=false
            log_warn "Layer 3 check failed: package 'pika-backup' is not installed"
            failure_issues+=("Layer 3: pika-backup package not installed")
        fi

        if [[ -z "${BACKUP_MOUNT:-}" || ! -d "${BACKUP_MOUNT}/Personal" ]]; then
            l3_ok=false
            log_warn "Layer 3 check failed: directory '${BACKUP_MOUNT:-}/Personal' does not exist"
            failure_issues+=("Layer 3: ${BACKUP_MOUNT:-}/Personal directory missing")
        else
            local host_name="${DETECTED_HOSTNAME:-$(cat /etc/hostname 2>/dev/null || uname -n)}"
            local target_user
            target_user="$(effective_user)"
            local repo_path="${BACKUP_MOUNT}/Personal/backup-${host_name}-${target_user}"
            local borg_ec=0
            run_as_user env BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes BORG_PASSPHRASE="" timeout 5 borg info "$repo_path" >/dev/null 2>&1 || borg_ec=$?
            if [[ $borg_ec -ne 0 && $borg_ec -ne 2 ]] && [[ ! -f "$repo_path/config" || ! -d "$repo_path/data" ]]; then
                l3_ok=false
                log_warn "Layer 3 check failed: Borg repository at $repo_path is invalid or inaccessible (borg info exit code $borg_ec)"
                failure_issues+=("Layer 3: Borg repository inaccessible or not initialized in Pika Backup")
            fi
        fi

        if $l3_ok; then
            layer3_status="✓ OK"
            log_success "Layer 3 (Pika Backup): All checks passed"
        else
            layer3_status="✗ ISSUES"
            all_passed=false
            log_error "Layer 3 (Pika Backup): Verification failed"
        fi
    else
        log_info "Layer 3 (Pika Backup): Skipped (not selected)"
    fi

    # ── 4. Check Layer 4 (Cloud Offsite) ──────────────────────────────────────
    local layer4_status="— Skipped"
    if layer_selected "$LAYER_CLOUD"; then
        log_info "Validating Layer 4 (Cloud Offsite)..."
        local l4_ok=true

        if ! pkg_is_installed rclone || ! pkg_is_installed age; then
            l4_ok=false
            log_warn "Layer 4 check failed: packages 'rclone' or 'age' are not installed"
            failure_issues+=("Layer 4: rclone or age package not installed")
        fi

        if layer_selected "$LAYER_BTRBK"; then
            local age_key_file="${user_home}/.config/arch-backup-wizard/cloud_os.key"
            if [[ ! -f "$age_key_file" ]]; then
                l4_ok=false
                log_warn "Layer 4 check failed: Age encryption key $age_key_file is missing"
                failure_issues+=("Layer 4: Age encryption key missing")
            fi

            if [[ ! -f "${user_home}/.os_cloud_backup.sh" || ! -x "${user_home}/.os_cloud_backup.sh" ]]; then
                l4_ok=false
                log_warn "Layer 4 check failed: ${user_home}/.os_cloud_backup.sh does not exist or is not executable"
                failure_issues+=("Layer 4: ~/.os_cloud_backup.sh missing or not executable")
            else
                # Extract the remote from the script and test it
                local cloud_remote
                cloud_remote=$(grep -oP 'rclone copy.*"\K[^"]+(?=")' "${user_home}/.os_cloud_backup.sh" | awk -F':' '{print $1":"}' | head -n 1 || true)
                if [[ -n "$cloud_remote" ]] && ! run_as_user rclone lsd "$cloud_remote" >/dev/null 2>&1; then
                    l4_ok=false
                    log_warn "Layer 4 check failed: 'rclone lsd $cloud_remote' failed"
                    failure_issues+=("Layer 4: rclone connection test failed for $cloud_remote")
                fi
            fi

            if [[ ! -f "${user_home}/.os_clone_nag.sh" || ! -x "${user_home}/.os_clone_nag.sh" ]]; then
                l4_ok=false
                log_warn "Layer 4 check failed: ${user_home}/.os_clone_nag.sh does not exist or is not executable"
                failure_issues+=("Layer 4: ~/.os_clone_nag.sh missing or not executable")
            fi

            # Check nag script hook in shell startup file or XDG autostart
            local hook_found=false
            local shell_bin
            shell_bin=$(basename "${DETECTED_SHELL:-bash}")
            local rc_file=""
            case "$shell_bin" in
            zsh) rc_file="${user_home}/.zshrc" ;;
            fish) rc_file="${user_home}/.config/fish/config.fish" ;;
            bash | *) rc_file="${user_home}/.bashrc" ;;
            esac

            local desktop_autostart="${user_home}/.config/autostart/os-clone-nag.desktop"
            if [[ -f "$rc_file" ]] && grep -Fq ".os_clone_nag.sh" "$rc_file"; then
                hook_found=true
            elif [[ -f "$desktop_autostart" ]] && grep -Fq ".os_clone_nag.sh" "$desktop_autostart"; then
                hook_found=true
            fi

            if ! $hook_found; then
                l4_ok=false
                log_warn "Layer 4 check failed: nag script hook not found in $rc_file or $desktop_autostart"
                failure_issues+=("Layer 4: nag script hook missing in $(basename "$rc_file") or autostart")
            fi
        fi

        if layer_selected "$LAYER_PIKA"; then
            if [[ ! -f "/etc/systemd/system/pika-cloud-sync.timer" ]]; then
                l4_ok=false
                log_warn "Layer 4 check failed: /etc/systemd/system/pika-cloud-sync.timer does not exist"
                failure_issues+=("Layer 4: pika-cloud-sync.timer missing")
            else
                if ! systemctl is-enabled pika-cloud-sync.timer >/dev/null 2>&1; then
                    l4_ok=false
                    log_warn "Layer 4 check failed: pika-cloud-sync.timer is not enabled"
                    failure_issues+=("Layer 4: pika-cloud-sync.timer not enabled")
                fi
                if ! systemctl is-active pika-cloud-sync.timer >/dev/null 2>&1; then
                    l4_ok=false
                    log_warn "Layer 4 check failed: pika-cloud-sync.timer is not active (running)"
                    failure_issues+=("Layer 4: pika-cloud-sync.timer not active")
                fi
            fi
        fi

        if $l4_ok; then
            layer4_status="✓ OK"
            log_success "Layer 4 (Cloud Offsite): All checks passed"
        else
            layer4_status="✗ ISSUES"
            all_passed=false
            log_error "Layer 4 (Cloud Offsite): Verification failed"
        fi
    else
        log_info "Layer 4 (Cloud Offsite): Skipped (not selected)"
    fi

    # ── 5. Check Layer 5 (Deep Storage) ───────────────────────────────────────
    local layer5_status="— Skipped"
    if layer_selected "$LAYER_DEEP"; then
        log_info "Validating Layer 5 (Deep Storage)..."
        local l5_ok=true

        if [[ -z "${BACKUP_MOUNT:-}" || ! -d "${BACKUP_MOUNT}/Deep Storage" ]]; then
            l5_ok=false
            log_warn "Layer 5 check failed: directory '${BACKUP_MOUNT:-}/Deep Storage' does not exist"
            failure_issues+=("Layer 5: '${BACKUP_MOUNT:-}/Deep Storage' directory missing")
        fi

        if $l5_ok; then
            layer5_status="✓ OK"
            log_success "Layer 5 (Deep Storage): All checks passed"
        else
            layer5_status="✗ ISSUES"
            all_passed=false
            log_error "Layer 5 (Deep Storage): Verification failed"
        fi
    else
        log_info "Layer 5 (Deep Storage): Skipped (not selected)"
    fi

    # ── 6. Check cross-layer items ────────────────────────────────────────────
    local check_fstab=false
    for l in "$LAYER_BTRBK" "$LAYER_PIKA" "$LAYER_DEEP"; do
        layer_selected "$l" && check_fstab=true
    done

    local fstab_status="—"
    if $check_fstab && [[ -n "${BACKUP_MOUNT:-}" ]]; then
        log_info "Checking /etc/fstab for backup drive mount ($BACKUP_MOUNT)..."
        local fstab_line=""
        if [[ -f /etc/fstab ]]; then
            fstab_line=$(awk -v m1="$BACKUP_MOUNT" -v m2="${BACKUP_MOUNT// /\\040}" '$1 !~ /^#/ && ($2 == m1 || $2 == m2) {print; exit}' /etc/fstab 2>/dev/null || true)
            if [[ -z "$fstab_line" && -n "${BACKUP_UUID:-}" ]]; then
                fstab_line=$(awk -v uuid="UUID=$BACKUP_UUID" '$1 !~ /^#/ && $1 == uuid {print; exit}' /etc/fstab 2>/dev/null || true)
            fi
        fi

        if [[ -n "$fstab_line" ]] && grep -qE '(^|[[:space:],])nofail([[:space:],]|$)' <<<"$fstab_line"; then
            fstab_status="✓"
            log_success "Backup drive ($BACKUP_MOUNT) found in /etc/fstab with 'nofail'"
        else
            fstab_status="✗"
            all_passed=false
            if [[ -z "$fstab_line" ]]; then
                log_warn "Backup drive ($BACKUP_MOUNT) is missing from /etc/fstab"
                failure_issues+=("fstab: Backup drive ($BACKUP_MOUNT) missing from /etc/fstab")
            else
                log_warn "Backup drive entry in /etc/fstab is missing 'nofail': $fstab_line"
                failure_issues+=("fstab: Backup drive entry missing 'nofail' option")
            fi
        fi
    else
        fstab_status="—"
        log_info "No layers requiring backup drive selected; skipping /etc/fstab validation"
    fi

    log_info "Checking for recovery runbooks..."
    local runbook_count=0
    local runbook_dir="${BACKUP_MOUNT:-${user_home}/Backup}"
    if [[ -d "$runbook_dir" ]]; then
        local runbook_files=()
        local prev_nullglob
        prev_nullglob=$(shopt -p nullglob || true)
        shopt -s nullglob
        runbook_files=("$runbook_dir"/*Runbook*.txt)
        eval "$prev_nullglob"
        runbook_count=${#runbook_files[@]}
    fi

    local missing_runbooks=()
    if layer_selected "$LAYER_SNAPPER" && [[ ! -f "$runbook_dir/Layer1_Snapper_Rollback_Runbook.txt" ]]; then
        missing_runbooks+=("Layer 1 Rollback Runbook (Layer1_Snapper_Rollback_Runbook.txt)")
    fi
    if layer_selected "$LAYER_BTRBK" && [[ ! -f "$runbook_dir/Bare_Metal_Recovery_Runbook.txt" ]]; then
        missing_runbooks+=("Layer 2 Bare-Metal Recovery Runbook (Bare_Metal_Recovery_Runbook.txt)")
    fi
    if layer_selected "$LAYER_CLOUD" && layer_selected "$LAYER_BTRBK" && [[ ! -f "$runbook_dir/Cloud_Recovery_Runbook.txt" ]]; then
        missing_runbooks+=("Layer 4 Cloud Recovery Runbook (Cloud_Recovery_Runbook.txt)")
    fi

    if [[ ${#missing_runbooks[@]} -gt 0 ]]; then
        log_warn "Missing expected recovery runbooks in $runbook_dir: ${missing_runbooks[*]}"
        all_passed=false
        for mrb in "${missing_runbooks[@]}"; do
            failure_issues+=("Runbooks: Missing $mrb in $runbook_dir")
        done
    elif [[ $runbook_count -gt 0 ]]; then
        log_success "All expected recovery runbooks found ($runbook_count total in $runbook_dir)"
    else
        log_info "No recovery runbooks expected for the selected layers"
    fi

    # ── 7. Build summary dashboard ────────────────────────────────────────────
    local dashboard=""
    dashboard+="Layer 1: Snapper .............. ${layer1_status}"$'\n'
    dashboard+="Layer 2: btrbk ................ ${layer2_status}"$'\n'
    dashboard+="Layer 3: Pika Backup .......... ${layer3_status}"$'\n'
    dashboard+="Layer 4: Cloud Offsite ........ ${layer4_status}"$'\n'
    dashboard+="Layer 5: Deep Storage ......... ${layer5_status}"$'\n\n'
    dashboard+="Backup drive in fstab: ${fstab_status}"$'\n'
    dashboard+="Recovery runbooks: ${runbook_count} found"$'\n\n'

    if $all_passed; then
        dashboard+="All checks passed!"
        log_success "══════ Post-Setup Validation: All checks passed! ══════"
    else
        dashboard+="WARNING: Issues were detected during validation!"$'\n\n'
        dashboard+="Issues:"$'\n'
        for issue in "${failure_issues[@]}"; do
            dashboard+="  • ${issue}"$'\n'
        done
        dashboard+=$'\n'"Please check log file for details:"$'\n'
        dashboard+="  ${LOG_FILE:-/tmp/arch-backup-wizard.log}"
        log_error "══════ Post-Setup Validation: Issues detected (${#failure_issues[@]}) ══════"
        for issue in "${failure_issues[@]}"; do
            log_error "  - ${issue}"
        done
    fi

    if [[ -t 1 ]] && command -v "${DIALOG_CMD:-dialog}" &>/dev/null; then
        ui_msgbox "Validation Results" "$dashboard"
    fi
    echo "$dashboard"

    if $all_passed; then
        return 0
    else
        return 1
    fi
}
