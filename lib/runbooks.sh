#!/usr/bin/env bash
# arch-backup-wizard/lib/runbooks.sh — Recovery runbook generation module
#
# Generates personalized, step-by-step disaster recovery runbooks with
# the user's actual UUIDs, paths, and system configuration baked in.

# Ensure layer_selected function exists if running outside wizard.sh
if ! declare -F layer_selected >/dev/null 2>&1; then
    layer_selected() {
        local target="$1"
        if [[ -n "${SELECTED_LAYERS+x}" ]]; then
            for l in "${SELECTED_LAYERS[@]}"; do
                [[ "$l" == "$target" ]] && return 0
            done
        fi
        return 1
    }
fi

# Generate personalized recovery runbooks based on configured layers
generate_runbooks() {
    log_info "── Generating Personalized Recovery Runbooks ──"

    # Resolve WIZARD_DIR if not already set
    local wizard_dir="${WIZARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # Ensure BACKUP_MOUNT is set and directory exists
    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        local default_home="${DETECTED_HOME:-$(get_real_home)}"
        BACKUP_MOUNT="${default_home:-/root}/Backup"
        log_warn "BACKUP_MOUNT is not set; defaulting runbook destination to ${BACKUP_MOUNT}"
    fi

    if [[ ! -d "$BACKUP_MOUNT" ]]; then
        mkdir -p "$BACKUP_MOUNT"
    fi

    # 1. Set up all template variables that the runbook templates need.
    # These are exported as regular shell variables that template_render() will substitute:
    export ROOT_UUID="${DETECTED_ROOT_UUID:-}"
    export EFI_UUID="${DETECTED_EFI_UUID:-}"
    export BOOTLOADER="${DETECTED_BOOTLOADER:-}"
    export USERNAME="${DETECTED_USER:-$(get_real_user)}"
    export HOME_DIR="${DETECTED_HOME:-$(get_real_home)}"
    export HOSTNAME_VAL="${DETECTED_HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")}"
    export BACKUP_MOUNT="${BACKUP_MOUNT:-}"
    export BACKUP_UUID="${BACKUP_UUID:-}"
    export ROOT_SUBVOL="${DETECTED_ROOT_SUBVOL:-}"
    export SUBVOL_LAYOUT="${DETECTED_SUBVOL_LAYOUT:-}"
    export DISTRO="${DETECTED_DISTRO:-Arch Linux}"
    export CLOUD_REMOTE="${CLOUD_REMOTE:-${LAYER4_CLOUD_REMOTE:-}}"
    export CLOUD_OS_DIR="${CLOUD_OS_DIR:-${LAYER4_CLOUD_OS_DIR:-}}"
    export CLOUD_PIKA_DIR="${CLOUD_PIKA_DIR:-${LAYER4_CLOUD_PIKA_DIR:-}}"

    log_info "Exported template variables for runbook generation:"
    log_info "  ROOT_UUID=$ROOT_UUID"
    log_info "  EFI_UUID=$EFI_UUID"
    log_info "  BOOTLOADER=$BOOTLOADER"
    log_info "  USERNAME=$USERNAME"
    log_info "  HOME_DIR=$HOME_DIR"
    log_info "  HOSTNAME_VAL=$HOSTNAME_VAL"
    log_info "  BACKUP_MOUNT=$BACKUP_MOUNT"
    log_info "  BACKUP_UUID=$BACKUP_UUID"
    log_info "  ROOT_SUBVOL=$ROOT_SUBVOL"
    log_info "  SUBVOL_LAYOUT=$SUBVOL_LAYOUT"
    log_info "  DISTRO=$DISTRO"
    log_info "  CLOUD_REMOTE=$CLOUD_REMOTE"
    log_info "  CLOUD_OS_DIR=$CLOUD_OS_DIR"
    log_info "  CLOUD_PIKA_DIR=$CLOUD_PIKA_DIR"

    local target_user="${DETECTED_USER:-$(get_real_user)}"
    local generated_runbooks=()
    local missing_templates=()

    # 2. Generate Layer 1 Rollback Runbook (only if Layer 1 was configured)
    if layer_selected "1"; then
        local tpl1="$wizard_dir/templates/rollback-runbook.txt"
        local out1="$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt"

        if [[ -f "$tpl1" ]]; then
            log_info "Generating Layer 1 Rollback Runbook..."
            if [[ -f "$out1" ]]; then
                backup_file "$out1" >/dev/null
            fi
            template_render "$tpl1" "$out1"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:$target_user" "$out1" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 1: Snapper Rollback Runbook (Layer1_Snapper_Rollback_Runbook.txt)")
            log_success "Generated Layer 1 Rollback Runbook: $out1"
        else
            log_warn "Template not found: $tpl1 — skipping Layer 1 runbook generation"
            missing_templates+=("rollback-runbook.txt (Layer 1)")
        fi
    fi

    # 3. Generate Bare-Metal Recovery Runbook (only if Layer 2 was configured)
    if layer_selected "2"; then
        local tpl2="$wizard_dir/templates/bare-metal-runbook.txt"
        local out2="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"

        if [[ -f "$tpl2" ]]; then
            log_info "Generating Bare-Metal Recovery Runbook..."
            if [[ -f "$out2" ]]; then
                backup_file "$out2" >/dev/null
            fi
            template_render "$tpl2" "$out2"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:$target_user" "$out2" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 2: Bare-Metal Recovery Runbook (Bare_Metal_Recovery_Runbook.txt)")
            log_success "Generated Bare-Metal Recovery Runbook: $out2"
        else
            log_warn "Template not found: $tpl2 — skipping Layer 2 runbook generation"
            missing_templates+=("bare-metal-runbook.txt (Layer 2)")
        fi
    fi

    # 4. Generate Cloud Recovery Runbook (only if Layer 4 was configured)
    if layer_selected "4"; then
        local tpl4="$wizard_dir/templates/cloud-recovery-runbook.txt"
        local out4="$BACKUP_MOUNT/Cloud_Recovery_Runbook.txt"

        if [[ -f "$tpl4" ]]; then
            log_info "Generating Cloud Recovery Runbook..."
            if [[ -f "$out4" ]]; then
                backup_file "$out4" >/dev/null
            fi
            template_render "$tpl4" "$out4"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:$target_user" "$out4" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 4: Cloud Recovery Runbook (Cloud_Recovery_Runbook.txt)")
            log_success "Generated Cloud Recovery Runbook: $out4"
        else
            log_warn "Template not found: $tpl4 — skipping Layer 4 runbook generation"
            missing_templates+=("cloud-recovery-runbook.txt (Layer 4)")
        fi
    fi

    # 5. Show a ui_msgbox summarizing which runbooks were generated and where they are saved.
    local summary=""
    if [[ ${#generated_runbooks[@]} -gt 0 ]]; then
        summary="The following recovery runbooks have been generated:"$'\n\n'
        for rb in "${generated_runbooks[@]}"; do
            summary+="  • ${rb}"$'\n'
        done
        summary+=$'\n'"Saved to:"$'\n'"  ${BACKUP_MOUNT}"$'\n\n'
        summary+="IMPORTANT:"$'\n'
        summary+="These runbooks contain your system's exact UUIDs, partition"$'\n'
        summary+="layouts, and recovery commands. Keep a copy on an offline"$'\n'
        summary+="USB drive or print them out for emergency disaster recovery."
        if [[ ${#missing_templates[@]} -gt 0 ]]; then
            summary+=$'\n\n'"Note: The following templates were missing:"$'\n'
            for mt in "${missing_templates[@]}"; do
                summary+="  • ${mt}"$'\n'
            done
        fi
    else
        summary="No recovery runbooks were generated."$'\n'
        if [[ ${#missing_templates[@]} -gt 0 ]]; then
            summary+=$'\n'"The following templates were not found:"$'\n'
            for mt in "${missing_templates[@]}"; do
                summary+="  • ${mt}"$'\n'
            done
        else
            summary+=$'\n'"(No layers requiring recovery runbooks were selected.)"
        fi
    fi

    ui_msgbox "Recovery Runbooks" "$summary"
    log_info "Runbook summary displayed to user."
}

export -f generate_runbooks
