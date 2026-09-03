#!/usr/bin/env bash
# arch-backup-wizard/lib/validate.sh — Post-setup health checks and validation dashboard
#
# Runs comprehensive verification across all configured backup layers,
# cross-layer configurations (fstab, recovery runbooks), and displays
# a health summary dashboard via dialog.

# Ensure layer_selected function exists if running outside wizard.sh
if ! declare -F layer_selected >/dev/null 2>&1; then
    layer_selected() {
        local target="$1"
        if [[ -n "${SELECTED_LAYERS+x}" ]]; then
            for l in "${SELECTED_LAYERS[@]}"; do
                [[ "$l" == "$target" ]] && return 0
            done
            return 1
        fi
        return 0
    }
fi

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
    local user_home="${DETECTED_HOME:-$(get_real_home 2>/dev/null || echo "$HOME")}"

    # ── 1. Check Layer 1 (Snapper) ────────────────────────────────────────────
    local layer1_status="— Skipped"
    if layer_selected "1"; then
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

        if [[ ! -f /usr/share/libalpm/hooks/05-snap-pac-pre.hook && ! -f /usr/share/libalpm/hooks/zz-snap-pac-post.hook ]]; then
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
    if layer_selected "2"; then
        log_info "Validating Layer 2 (btrbk)..."
        local l2_ok=true

        if ! pkg_is_installed btrbk; then
            l2_ok=false
            log_warn "Layer 2 check failed: package 'btrbk' is not installed"
            failure_issues+=("Layer 2: btrbk package not installed")
        fi

        if [[ ! -f /etc/btrbk/btrbk.conf ]]; then
            l2_ok=false
            log_warn "Layer 2 check failed: /etc/btrbk/btrbk.conf does not exist"
            failure_issues+=("Layer 2: /etc/btrbk/btrbk.conf missing")
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
    if layer_selected "3"; then
        log_info "Validating Layer 3 (Pika Backup)..."
        local l3_ok=true

        if ! pkg_is_installed pika-backup; then
            l3_ok=false
            log_warn "Layer 3 check failed: package 'pika-backup' is not installed"
            failure_issues+=("Layer 3: pika-backup package not installed")
        fi

        if [[ ! -f "${user_home}/.config/pika-backup/backup.json" ]]; then
            l3_ok=false
            log_warn "Layer 3 check failed: ${user_home}/.config/pika-backup/backup.json does not exist"
            failure_issues+=("Layer 3: Pika backup.json config missing")
        fi

        if [[ -z "${BACKUP_MOUNT:-}" || ! -d "${BACKUP_MOUNT}/Personal" ]]; then
            l3_ok=false
            log_warn "Layer 3 check failed: directory '${BACKUP_MOUNT:-}/Personal' does not exist"
            failure_issues+=("Layer 3: ${BACKUP_MOUNT:-}/Personal directory missing")
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
    if layer_selected "4"; then
        log_info "Validating Layer 4 (Cloud Offsite)..."
        local l4_ok=true

        if ! pkg_is_installed rclone; then
            l4_ok=false
            log_warn "Layer 4 check failed: package 'rclone' is not installed"
            failure_issues+=("Layer 4: rclone package not installed")
        fi

        if [[ ! -f "${user_home}/.os_cloud_backup.sh" || ! -x "${user_home}/.os_cloud_backup.sh" ]]; then
            l4_ok=false
            log_warn "Layer 4 check failed: ${user_home}/.os_cloud_backup.sh does not exist or is not executable"
            failure_issues+=("Layer 4: ~/.os_cloud_backup.sh missing or not executable")
        fi

        if [[ ! -f "${user_home}/.os_clone_nag.sh" || ! -x "${user_home}/.os_clone_nag.sh" ]]; then
            l4_ok=false
            log_warn "Layer 4 check failed: ${user_home}/.os_clone_nag.sh does not exist or is not executable"
            failure_issues+=("Layer 4: ~/.os_clone_nag.sh missing or not executable")
        fi

        if [[ ! -f "${user_home}/.config/systemd/user/pika-cloud-sync.timer" ]]; then
            l4_ok=false
            log_warn "Layer 4 check failed: ${user_home}/.config/systemd/user/pika-cloud-sync.timer does not exist"
            failure_issues+=("Layer 4: pika-cloud-sync.timer missing")
        fi

        # Check nag script hook in shell startup file
        local shell_bin
        shell_bin=$(basename "${DETECTED_SHELL:-bash}")
        local rc_file=""
        case "$shell_bin" in
            zsh)    rc_file="${user_home}/.zshrc" ;;
            fish)   rc_file="${user_home}/.config/fish/config.fish" ;;
            bash|*) rc_file="${user_home}/.bashrc" ;;
        esac

        if [[ ! -f "$rc_file" ]] || ! grep -Fq ".os_clone_nag.sh" "$rc_file"; then
            l4_ok=false
            log_warn "Layer 4 check failed: nag script not configured in $rc_file"
            failure_issues+=("Layer 4: nag script hook missing in $(basename "$rc_file")")
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
    if layer_selected "5"; then
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
    local fstab_status="✓"
    if [[ -n "${BACKUP_MOUNT:-}" ]]; then
        log_info "Checking /etc/fstab for backup drive mount ($BACKUP_MOUNT)..."
        local fstab_line=""
        if [[ -f /etc/fstab ]]; then
            fstab_line=$(grep -v '^[[:space:]]*#' /etc/fstab 2>/dev/null | grep -F "$BACKUP_MOUNT" | head -n 1 || true)
            if [[ -z "$fstab_line" && -n "${BACKUP_UUID:-}" ]]; then
                fstab_line=$(grep -v '^[[:space:]]*#' /etc/fstab 2>/dev/null | grep -F "$BACKUP_UUID" | head -n 1 || true)
            fi
        fi

        if [[ -n "$fstab_line" ]] && grep -qE '(^|[[:space:],])nofail([[:space:],]|$)' <<< "$fstab_line"; then
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
        log_info "BACKUP_MOUNT not set; skipping /etc/fstab validation"
    fi

    log_info "Checking for recovery runbooks..."
    local runbook_count=0
    if [[ -n "${BACKUP_MOUNT:-}" && -d "$BACKUP_MOUNT" ]]; then
        local runbook_files=()
        local prev_nullglob
        prev_nullglob=$(shopt -p nullglob || true)
        shopt -s nullglob
        runbook_files=("$BACKUP_MOUNT"/*Runbook*.txt)
        eval "$prev_nullglob"
        runbook_count=${#runbook_files[@]}
    fi

    if [[ $runbook_count -gt 0 ]]; then
        log_success "Recovery runbooks: $runbook_count found in ${BACKUP_MOUNT:-N/A}"
    else
        log_warn "Recovery runbooks: 0 found in ${BACKUP_MOUNT:-N/A}"
        if layer_selected "1" || layer_selected "2" || layer_selected "4"; then
            all_passed=false
            failure_issues+=("Runbooks: No recovery runbooks found in ${BACKUP_MOUNT:-N/A}")
        fi
    fi

    # ── 7. Build summary dashboard ────────────────────────────────────────────
    local dashboard=""
    dashboard+="Layer 1: Snapper .............. ${layer1_status}"$'\n'
    dashboard+="Layer 2: btrbk ............... ${layer2_status}"$'\n'
    dashboard+="Layer 3: Pika Backup ......... ${layer3_status}"$'\n'
    dashboard+="Layer 4: Cloud Offsite ....... ${layer4_status}"$'\n'
    dashboard+="Layer 5: Deep Storage ........ ${layer5_status}"$'\n\n'
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

    ui_msgbox "Validation Results" "$dashboard"

    if $all_passed; then
        return 0
    else
        return 1
    fi
}

export -f run_validation
