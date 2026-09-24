#!/usr/bin/env bash
# arch-backup-wizard/lib/layer2_btrbk.sh — Layer 2: btrbk daily OS clone setup
#
# Configures btrbk to create daily snapshots of the root filesystem
# and transfer them to the secondary backup drive for disaster recovery.

setup_layer2() {
    log_info "── Setting up Layer 2: btrbk daily OS clones ──"

    if [[ -z "${LOG_FILE:-}" ]]; then
        log_error "LOG_FILE is not set. Cannot proceed."
        return 1
    fi

    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        log_error "BACKUP_MOUNT is not set. Layer 2 requires a configured backup drive."
        ui_msgbox "Configuration Error" "Backup mount point is not set. Please configure the backup drive first."
        return 1
    fi

    local backup_mount="${BACKUP_MOUNT%/}"

    if [[ -z "$backup_mount" || "$backup_mount" == "/" ]]; then
        log_error "BACKUP_MOUNT resolves to the root filesystem ('$BACKUP_MOUNT'). Refusing to back up onto the source volume."
        ui_msgbox "Configuration Error" "The backup mount point must be a separate filesystem, not '/'."
        return 1
    fi

    if ! mountpoint -q "$backup_mount" 2>/dev/null; then
        log_error "$backup_mount is not a mounted filesystem. Mount the backup drive before running Layer 2."
        ui_msgbox "Configuration Error" "Backup drive at $backup_mount is not mounted."
        return 1
    fi

    # 1. Install packages: call install_layer_packages "2"
    log_info "Step 1: Installing Layer 2 packages..."
    if ! install_layer_packages "2"; then
        log_error "Failed to install Layer 2 packages."
        return 1
    fi
    log_info "Step 2: Ensuring backup target directory $backup_mount/OS_Backup exists..."
    mkdir -p "$backup_mount/OS_Backup" || {
        log_error "Failed to create $backup_mount/OS_Backup"
        return 1
    }

    # Verify the target is writable
    if ! touch "$backup_mount/OS_Backup/.write_test" 2>/dev/null; then
        log_error "Backup target $backup_mount/OS_Backup is not writable."
        return 1
    fi
    rm -f "$backup_mount/OS_Backup/.write_test"

    # Warn if free space is suspiciously low (< 1 GiB)
    local free_kb
    free_kb=$(df --output=avail -k "$backup_mount" 2>/dev/null | tail -1 | tr -d ' ')
    if [[ -n "$free_kb" && "$free_kb" -lt 1048576 ]]; then
        log_warn "Backup target has only $((free_kb / 1024)) MiB free. A full OS clone may not fit."
        ui_msgbox "Low Disk Space" \
            "The backup drive has less than 1 GiB of free space.
The initial OS clone may fail. Continue anyway?"
    fi

    log_info "Step 3: Writing $BTRBK_CONF..."
    mkdir -p "$(dirname "$BTRBK_CONF")" || {
        log_error "Failed to create $(dirname "$BTRBK_CONF")"
        return 1
    }
    backup_file "$BTRBK_CONF" || {
        log_error "Failed to back up existing $BTRBK_CONF before overwriting."
        return 1
    }

    record_manifest "$BTRBK_CONF"

    local _v
    for _v in BTRBK_SNAP_MIN BTRBK_SNAP BTRBK_TARGET_MIN BTRBK_TARGET; do
        if ! [[ "${!_v:-}" =~ ^[0-9]+$ ]] || [[ "${!_v}" -lt 1 ]]; then
            log_error "$_v is unset or not a positive integer (got '${!_v:-}')."
            return 1
        fi
    done

    cat <<EOF >"$BTRBK_CONF"
transaction_log            /var/log/btrbk.log
snapshot_preserve_min      ${BTRBK_SNAP_MIN}
snapshot_preserve          ${BTRBK_SNAP}
target_preserve_min        ${BTRBK_TARGET_MIN}
target_preserve            ${BTRBK_TARGET}
EOF

    local mnt subvol subvol_safe snap_dir
    for mount_pair in "${DETECTED_SUBVOL_MOUNTS[@]}"; do
        mnt="${mount_pair%%:*}"
        subvol="${mount_pair##*:}"
        subvol_safe="${subvol//\//_}"
        snap_dir="${mnt%/}/${SNAP_DIR_BTRBK#/}"

        # Make sure the mount point is actually mounted
        if ! mountpoint -q "$mnt" 2>/dev/null; then
            log_error "Mount point $mnt is not currently mounted. Cannot create snapshot directory."
            return 1
        fi

        if [[ ! -d "$snap_dir" ]]; then
            mkdir -p "$snap_dir" || {
                log_error "Failed to create snapshot directory: $snap_dir"
                return 1
            }
        fi

        cat <<EOF >>"$BTRBK_CONF"

volume "${mnt}"
  snapshot_dir               "${SNAP_DIR_BTRBK#/}"
  snapshot_name              "${subvol_safe}"
  subvolume .
  target send-receive "${backup_mount}/OS_Backup"
EOF
    done

    local vol_count
    vol_count=$(grep -c '^volume ' "$BTRBK_CONF" 2>/dev/null || echo 0)
    if [[ "$vol_count" -eq 0 ]]; then
        log_error "No subvolume mount pairs were detected. btrbk.conf contains no volume entries."
        ui_msgbox "Configuration Error" \
            "No btrfs subvolumes were detected for backup.
Please verify your btrfs layout and re-run Layer 2."
        return 1
    fi

    log_success "Created $BTRBK_CONF"

    log_info "Step 4: Configuring systemd drop-in override for btrbk.service..."
    local override_dir="${BTRBK_OVERRIDE_DIR:-/etc/systemd/system/btrbk.service.d}"
    local override_conf="$override_dir/override.conf"

    if [[ -z "$override_dir" ]]; then
        log_error "BTRBK_OVERRIDE_DIR is empty. Cannot write systemd drop-in."
        return 1
    fi

    mkdir -p "$override_dir" || {
        log_error "Failed to create $override_dir"
        return 1
    }
    backup_file "$override_conf" || {
        log_error "Failed to back up existing $override_conf before overwriting."
        return 1
    }

    record_manifest "$override_conf"
    cat <<EOF >"$override_conf"
[Unit]
RequiresMountsFor=$backup_mount

[Service]
ExecStart=
ExecStart=/usr/bin/btrbk run --config $BTRBK_CONF
Nice=19
IOSchedulingClass=idle
EOF
    log_success "Created $override_conf"

    # 5. Run systemctl daemon-reload
    log_info "Step 5: Reloading systemd daemon..."
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || {
        log_error "systemctl daemon-reload failed"
        return 1
    }

    log_info "Step 6: Enabling and starting btrbk.timer..."
    systemctl enable --now btrbk.timer >>"$LOG_FILE" 2>&1 || {
        log_error "Failed to enable btrbk.timer"
        return 1
    }

    log_info "Step 7: Checking if user wants to perform initial backup..."
    if ui_yesno "Run Initial Backup" \
        "Would you like to run the first btrbk backup now?

This will create an initial root snapshot and clone it to:
  ${backup_mount}/OS_Backup

Depending on the size of your root filesystem, this may take a few minutes."; then
        log_info "User requested immediate backup run."
        ui_infobox "Running Backup" \
            "Running initial btrbk OS clone to ${backup_mount}/OS_Backup...

This may take several minutes. Please wait..."

        if btrbk run --config "$BTRBK_CONF" >>"$LOG_FILE" 2>&1; then
            log_success "Initial btrbk backup completed successfully."
            ui_msgbox "Backup Succeeded" \
                "The initial btrbk OS clone completed successfully!

Destination: ${backup_mount}/OS_Backup
Details logged to: $LOG_FILE"
        else
            log_warn "Initial btrbk backup finished with warnings or errors."
            ui_msgbox "Backup Notice" \
                "Initial btrbk backup finished with warnings or errors.

Please check the log file for details:
  $LOG_FILE"
        fi
    else
        log_info "User skipped initial btrbk backup."
    fi

    # 8. Verify: check that btrbk.timer is active (unit_is_active btrbk.timer) and show success/failure via ui_msgbox.
    log_info "Step 8: Verifying btrbk.timer status..."
    if unit_is_active btrbk.timer; then
        log_success "Layer 2 setup completed: btrbk.timer is active."
        ui_msgbox "Layer 2 — Success" \
            "Layer 2 (btrbk) setup is complete and verified!

  Status:    btrbk.timer is active
  Target:    ${backup_mount}/OS_Backup
  Config:    $BTRBK_CONF
  Schedule:  Daily backups (snap: ${BTRBK_SNAP}, target: ${BTRBK_TARGET})"
        return 0
    else
        log_error "Layer 2 verification failed: btrbk.timer is not active."
        ui_msgbox "Layer 2 — Verification Failed" \
            "Layer 2 configuration completed, but btrbk.timer is not active.

Please verify systemd timer status manually:
  systemctl status btrbk.timer

Log details:
  $LOG_FILE"
        return 1
    fi
}
