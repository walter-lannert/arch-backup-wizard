#!/usr/bin/env bash
# arch-backup-wizard/lib/runbooks.sh — Recovery runbook generation module
#
# Generates personalized, step-by-step disaster recovery runbooks with
# the user's actual UUIDs, paths, and system configuration baked in.

# Generate personalized recovery runbooks based on configured layers

generate_runbooks() {
    log_info "── Generating Personalized Recovery Runbooks ──"

    # Resolve WIZARD_DIR if not already set
    local wizard_dir="${WIZARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # Ensure BACKUP_MOUNT is set and directory exists
    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        BACKUP_MOUNT="$(effective_home)/Backup"
        log_warn "BACKUP_MOUNT is not set; defaulting runbook destination to ${BACKUP_MOUNT}"
    fi

    if [[ ! -d "$BACKUP_MOUNT" ]]; then
        mkdir -p "$BACKUP_MOUNT" || {
            log_error "Failed to create $BACKUP_MOUNT"
            return 1
        }
        if [[ -n "$target_user" && "$target_user" != "root" ]]; then
            chown "$target_user:" "$BACKUP_MOUNT" 2>/dev/null || true
        fi
    fi

    # 1. Set up all template variables that the runbook templates need.
    # These are exported as regular shell variables that template_render() will substitute:
    export ROOT_UUID="${DETECTED_ROOT_UUID:-}"
    export EFI_UUID="${DETECTED_EFI_UUID:-}"
    export BOOTLOADER="${DETECTED_BOOTLOADER:-}"
    export USERNAME
    USERNAME="$(effective_user)"
    export HOME_DIR
    HOME_DIR="$(effective_home)"
    export HOSTNAME_VAL="${DETECTED_HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")}"
    export BACKUP_MOUNT="${BACKUP_MOUNT:-}"
    export BACKUP_UUID="${BACKUP_UUID:-}"
    export ROOT_SUBVOL="${DETECTED_ROOT_SUBVOL:-}"
    export SUBVOL_LAYOUT="${DETECTED_SUBVOL_LAYOUT:-}"
    export DISTRO="${DETECTED_DISTRO:-Arch Linux}"
    export CLOUD_REMOTE="${CLOUD_REMOTE:-}"
    export CLOUD_OS_DIR="${CLOUD_OS_DIR:-}"
    export CLOUD_PIKA_DIR="${CLOUD_PIKA_DIR:-}"

    # Dynamically detect kernel and microcode for bare-metal EFI restoration
    local kernel_pkgs
    kernel_pkgs=$(pacman -Qsq '^linux' 2>/dev/null | grep -E '^linux(-cachyos(-[a-z0-9]+)?|-zen|-lts|-hardened)?(-headers)?$' | tr '\n' ' ' || true)
    [[ -z "${kernel_pkgs// /}" ]] && kernel_pkgs="linux linux-headers"
    local ucode_pkgs
    ucode_pkgs=$(pacman -Qsq ucode 2>/dev/null | tr '\n' ' ' || true)
    export KERNEL_PKGS="${kernel_pkgs} ${ucode_pkgs}"

    # Generate dynamic subvolume recovery script block for runbooks
    local restore_script=""
    local snap_root_subvol="${DETECTED_ROOT_SUBVOL:-@}"
    snap_root_subvol="${snap_root_subvol#/}"
    [[ -z "$snap_root_subvol" ]] && snap_root_subvol="@"

    restore_script+="cat << 'EOF' > /tmp/restore_subvols.sh"$'\n'
    restore_script+="#!/bin/bash"$'\n'
    restore_script+="set -euo pipefail"$'\n'
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local sub_safe="${sub//\//_}"
        restore_script+="echo \"Restoring subvolume: $sub\""$'\n'
        restore_script+="SNAP=\$(find /mnt/backup/OS_Backup -maxdepth 1 -mindepth 1 -type d -name \"${sub_safe}.*\" 2>/dev/null | sort -r | head -n 1 || true)"$'\n'
        restore_script+="if [[ -n \"\$SNAP\" ]]; then"$'\n'
        restore_script+="  echo \"  Sending \$SNAP...\""$'\n'
        restore_script+="  btrfs send \"\$SNAP\" | btrfs receive /mnt/new_os/"$'\n'
        restore_script+="  mkdir -p \"/mnt/new_os/\$(dirname \"$sub\")\""$'\n'
        restore_script+="  btrfs subvolume snapshot \"/mnt/new_os/\$(basename \"\$SNAP\")\" \"/mnt/new_os/$sub\""$'\n'
        restore_script+="  btrfs property set -ts \"/mnt/new_os/$sub\" ro false"$'\n'
        restore_script+="  btrfs subvolume delete \"/mnt/new_os/\$(basename \"\$SNAP\")\""$'\n'
        restore_script+="else"$'\n'
        restore_script+="  echo \"  Warning: No clone found for $sub. Creating empty subvolume.\""$'\n'
        restore_script+="  mkdir -p \"/mnt/new_os/\$(dirname \"$sub\")\""$'\n'
        restore_script+="  btrfs subvolume create \"/mnt/new_os/$sub\""$'\n'
        restore_script+="fi"$'\n'
    done <<< "$DETECTED_SUBVOLUMES"
    restore_script+="echo \"All subvolumes restored successfully.\""$'\n'
    restore_script+="EOF"$'\n'
    restore_script+="chmod +x /tmp/restore_subvols.sh"$'\n'
    restore_script+="/tmp/restore_subvols.sh"$'\n'

    # Generate dynamic cloud recovery script block for runbooks
    local cloud_restore_script=""
    cloud_restore_script+="cat << 'EOF' > /tmp/cloud_restore_subvols.sh"$'\n'
    cloud_restore_script+="#!/bin/bash"$'\n'
    cloud_restore_script+="set -euo pipefail"$'\n'
    cloud_restore_script+="echo \"Fetching list of cloud archives...\""$'\n'
    cloud_restore_script+="archives=\$(rclone lsf \"${CLOUD_REMOTE:-}${CLOUD_OS_DIR:-}/\" | grep '.btrfs.zst.age$' || true)"$'\n'
    cloud_restore_script+="if [[ -z \"\$archives\" ]]; then echo \"Error: No archives found.\"; exit 1; fi"$'\n'

    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local sub_safe="${sub//\//_}"
        cloud_restore_script+="echo \"Restoring subvolume: $sub\""$'\n'
        cloud_restore_script+="ARCHIVE=\$(echo \"\$archives\" | grep \"^${sub_safe}\\.\" | sort -r | head -n 1 || true)"$'\n'
        cloud_restore_script+="if [[ -n \"\$ARCHIVE\" ]]; then"$'\n'
        cloud_restore_script+="  echo \"  Streaming \$ARCHIVE...\""$'\n'
        cloud_restore_script+="  rclone cat \"${CLOUD_REMOTE:-}${CLOUD_OS_DIR:-}/\$ARCHIVE\" | pv | age -d -i /root/cloud_os.key | zstdcat | btrfs receive /mnt/new_os/"$'\n'
        cloud_restore_script+="  RECEIVED_NAME=\$(echo \"\$ARCHIVE\" | sed 's/\\.btrfs\\.zst\\.age$//')"$'\n'
        cloud_restore_script+="  mkdir -p \"/mnt/new_os/\$(dirname \"$sub\")\""$'\n'
        cloud_restore_script+="  btrfs subvolume snapshot \"/mnt/new_os/\$RECEIVED_NAME\" \"/mnt/new_os/$sub\""$'\n'
        cloud_restore_script+="  btrfs property set -ts \"/mnt/new_os/$sub\" ro false"$'\n'
        cloud_restore_script+="  btrfs subvolume delete \"/mnt/new_os/\$RECEIVED_NAME\""$'\n'
        cloud_restore_script+="else"$'\n'
        cloud_restore_script+="  echo \"  Warning: No clone found for $sub. Creating empty subvolume.\""$'\n'
        cloud_restore_script+="  mkdir -p \"/mnt/new_os/\$(dirname \"$sub\")\""$'\n'
        cloud_restore_script+="  btrfs subvolume create \"/mnt/new_os/$sub\""$'\n'
        cloud_restore_script+="fi"$'\n'
    done <<< "$DETECTED_SUBVOLUMES"
    cloud_restore_script+="echo \"All subvolumes restored successfully.\""$'\n'
    cloud_restore_script+="EOF"$'\n'
    cloud_restore_script+="chmod +x /tmp/cloud_restore_subvols.sh"$'\n'
    cloud_restore_script+="/tmp/cloud_restore_subvols.sh"$'\n'

    export CLOUD_RECOVERY_SCRIPT="$cloud_restore_script"
    export SUBVOL_RECOVERY_SCRIPT="$restore_script"
    export DETECTED_ROOT_SUBVOL_STR="$snap_root_subvol"

    # Generate dynamic mount commands
    local mount_cmds=""
    local mkdir_cmds=""
    for mount_pair in "${DETECTED_SUBVOL_MOUNTS[@]}"; do
        local mnt="${mount_pair%%:*}"
        local sub="${mount_pair#*:}"
        if [[ "$mnt" != "/" ]]; then
            mkdir_cmds+="  mkdir -p \"/mnt/target${mnt}\""$'\n'
            mount_cmds+="  mount -o subvol=\"${sub}\",compress=zstd /dev/NEW_ROOT_PARTITION \"/mnt/target${mnt}\""$'\n'
        fi
    done
    export SUBVOL_MKDIR_CMDS="$mkdir_cmds"
    export SUBVOL_MOUNT_CMDS="$mount_cmds"

    # EFI Mount Path
    export EFI_MOUNT_PATH="${DETECTED_EFI_MOUNT:-/boot}"

    # Snapshot layout
    local snap_layout="${snap_root_subvol}/.snapshots"
    if grep -qFx "@snapshots" <<<"$DETECTED_SUBVOLUMES"; then
        snap_layout="@snapshots"
    elif grep -qFx "@.snapshots" <<<"$DETECTED_SUBVOLUMES"; then
        snap_layout="@.snapshots"
    fi
    export SNAPSHOT_LAYOUT_PATH="$snap_layout"
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

    local target_user
    target_user="$(effective_user)"
    local generated_runbooks=()
    local missing_templates=()

    # 2. Generate Layer 1 Rollback Runbook (only if Layer 1 was configured)
    if layer_selected "$LAYER_SNAPPER"; then
        local tpl1="$wizard_dir/templates/rollback-runbook.txt"
        local out1="$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt"

        if [[ -f "$tpl1" ]]; then
            log_info "Generating Layer 1 Rollback Runbook..."
            if [[ -f "$out1" ]]; then
                backup_file "$out1" >/dev/null || return 1
            fi
            template_render "$tpl1" "$out1"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:" "$out1" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 1: Snapper Rollback Runbook (Layer1_Snapper_Rollback_Runbook.txt)")
            log_success "Generated Layer 1 Rollback Runbook: $out1"
        else
            log_warn "Template not found: $tpl1 — skipping Layer 1 runbook generation"
            missing_templates+=("rollback-runbook.txt (Layer 1)")
        fi
    fi

    # 3. Generate Bare-Metal Recovery Runbook (only if Layer 2 was configured)
    if layer_selected "$LAYER_BTRBK"; then
        local tpl2="$wizard_dir/templates/bare-metal-runbook.txt"
        local out2="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"

        if [[ -f "$tpl2" ]]; then
            log_info "Generating Bare-Metal Recovery Runbook..."
            if [[ -f "$out2" ]]; then
                backup_file "$out2" >/dev/null || return 1
            fi
            template_render "$tpl2" "$out2"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:" "$out2" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 2: Bare-Metal Recovery Runbook (Bare_Metal_Recovery_Runbook.txt)")
            log_success "Generated Bare-Metal Recovery Runbook: $out2"
        else
            log_warn "Template not found: $tpl2 — skipping Layer 2 runbook generation"
            missing_templates+=("bare-metal-runbook.txt (Layer 2)")
        fi
    fi

    # 4. Generate Cloud Recovery Runbook (only if Layer 4 and Layer 2 were configured)
    if layer_selected "$LAYER_CLOUD" && layer_selected "$LAYER_BTRBK"; then
        local tpl4="$wizard_dir/templates/cloud-recovery-runbook.txt"
        local out4="$BACKUP_MOUNT/Cloud_Recovery_Runbook.txt"

        if [[ -f "$tpl4" ]]; then
            log_info "Generating Cloud Recovery Runbook..."
            if [[ -f "$out4" ]]; then
                backup_file "$out4" >/dev/null || return 1
            fi
            template_render "$tpl4" "$out4"
            if [[ -n "$target_user" && "$target_user" != "root" ]]; then
                chown "$target_user:" "$out4" 2>/dev/null || true
            fi
            generated_runbooks+=("Layer 4: Cloud Recovery Runbook (Cloud_Recovery_Runbook.txt)")
            log_success "Generated Cloud Recovery Runbook: $out4"
            if [[ -n "${CLOUD_REMOTE:-}" && -n "${CLOUD_OS_DIR:-}" ]]; then
                if [[ "${DRY_RUN:-false}" == "true" ]]; then
                    log_info "DRY-RUN: Skipping rclone upload of $out4 to ${CLOUD_REMOTE}${CLOUD_OS_DIR}/"
                else
                    log_info "Uploading $out4 to ${CLOUD_REMOTE}${CLOUD_OS_DIR}/..."
                    run_as_user rclone copyto "$out4" "${CLOUD_REMOTE}${CLOUD_OS_DIR}/$(basename "$out4")" >>"$LOG_FILE" 2>&1 || true
                fi
            fi
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
