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

    # Mutual-exclusion lock to prevent concurrent invocations.
    local _lockfile="/var/lock/arch-backup-wizard-layer2.lock"
    exec 9>"$_lockfile" || {
        log_error "Cannot open lock file $_lockfile."
        return 1
    }
    if ! flock -n 9; then
        log_error "Another instance of Layer 2 setup is already running."
        ui_msgbox "Busy" "Another Layer 2 setup is in progress. Please wait for it to finish."
        return 1
    fi

    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        log_error "BACKUP_MOUNT is not set. Layer 2 requires a configured backup drive."
        return 1
    fi
    if [[ -z "${SNAP_DIR_BTRBK:-}" ]]; then
        log_error "SNAP_DIR_BTRBK is not set. Layer 2 requires SNAP_DIR_BTRBK to be configured."
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

    local _tgt_fstype
    _tgt_fstype=$(findmnt -no FSTYPE --target "$backup_mount" 2>/dev/null)
    if [[ "$_tgt_fstype" != "btrfs" ]]; then
        log_error "Backup target $backup_mount is filesystem type '$_tgt_fstype'. btrbk send-receive requires btrfs on the target."
        ui_msgbox "Configuration Error" \
            "The backup drive at $backup_mount is $_tgt_fstype, not btrfs.
btrbk send-receive requires a btrfs target.
Please format the backup drive as btrfs and re-run Layer 2."
        return 1
    fi

    # Verify the backup target is on a different physical device than every
    # source subvolume mount.
    local _src_dev _bdev
    _bdev=$(stat -c '%d' "$backup_mount" 2>/dev/null) || {
        log_error "Cannot determine device ID for $backup_mount."
        return 1
    }
    local mnt
    for mount_pair in "${DETECTED_SUBVOL_MOUNTS[@]}"; do
        mnt="${mount_pair%%:*}"
        _src_dev=$(stat -c '%d' "$mnt" 2>/dev/null) || continue
        if [[ "$_src_dev" == "$_bdev" ]]; then
            log_error "Backup target $backup_mount is on the SAME device as source $mnt. Refusing to proceed."
            ui_msgbox "Configuration Error" \
                "The backup drive and the source filesystem are on the same
physical device. A disk failure would destroy both the data and the backup.
Please use a separate disk."
            return 1
        fi
    done

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
    rm -f "$backup_mount/OS_Backup/.write_test" 2>/dev/null || \
        log_warn "Could not remove write-test file (harmless)."

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
        if ! [[ "${!_v:-}" =~ ^([0-9]+[dwmy]?|latest|no)$ ]]; then
            log_error "$_v is unset or invalid retention format (got '${!_v:-}')."
            return 1
        fi
        if [[ "${!_v}" =~ ^[0-9]+$ ]] && [[ "${!_v}" -gt 10000 ]]; then
            log_warn "$_v is set to ${!_v}, which is unusually high. btrbk will retain ${!_v} snapshots."
        fi
    done

    local _btrbk_log="/var/log/btrbk.log"
    if ! touch "$_btrbk_log" 2>/dev/null; then
        log_warn "Cannot write to $_btrbk_log; btrbk will log to stderr only."
        _btrbk_log=""
    fi
    if ! cat <<EOF >"$BTRBK_CONF"; then
transaction_log            ${_btrbk_log:-/dev/null}
snapshot_preserve_min      ${BTRBK_SNAP_MIN}
snapshot_preserve          ${BTRBK_SNAP}
target_preserve_min        ${BTRBK_TARGET_MIN}
target_preserve            ${BTRBK_TARGET}
EOF
        log_error "Failed to write $BTRBK_CONF"
        return 1
    fi

    local mnt subvol subvol_safe snap_dir
    for mount_pair in "${DETECTED_SUBVOL_MOUNTS[@]}"; do
        mnt="${mount_pair%%:*}"
        subvol="${mount_pair#*:}"
        subvol_safe=$(subvolume_to_snapshot_name "$subvol")
        snap_dir="${mnt%/}/${SNAP_DIR_BTRBK#/}"

        # Make sure the mount point is actually mounted
        if ! mountpoint -q "$mnt" 2>/dev/null; then
            log_error "Mount point $mnt is not currently mounted. Cannot create snapshot directory."
            return 1
        fi

        # Verify the filesystem type is btrfs before emitting subvolume directives.
        local _fstype
        _fstype=$(findmnt -no FSTYPE --target "$mnt" 2>/dev/null)
        if [[ "$_fstype" != "btrfs" ]]; then
            log_error "$mnt is filesystem type '$_fstype', not btrfs. Skipping."
            continue
        fi

        # Warn if this is the top-level subvolume (snapshot shares the same pool).
        local _top
        _top=$(btrfs subvolume list -s "$mnt" 2>/dev/null | awk '$2=="5" {print $NF}')
        if [[ -n "$_top" && "$_top" == "." ]]; then
            log_warn "Mount $mnt appears to be the top-level btrfs subvolume. Snapshots share the same allocation pool as the data."
        fi

        if [[ ! -d "$snap_dir" ]]; then
            mkdir -p "$snap_dir" || {
                log_error "Failed to create snapshot directory: $snap_dir"
                return 1
            }
        fi

        if ! cat <<EOF >>"$BTRBK_CONF"; then

volume "${mnt}"
  snapshot_dir               "${SNAP_DIR_BTRBK#/}"
  subvolume .
    snapshot_name              "${subvol_safe}"
    target send-receive "${backup_mount}/OS_Backup"
EOF
            log_error "Failed to write volume entry to $BTRBK_CONF"
            return 1
        fi
    done

    local vol_count
    vol_count=$(grep -c '^volume[[:space:]]' "$BTRBK_CONF" 2>/dev/null) || vol_count=0
    if [[ "$vol_count" -eq 0 ]]; then
        log_error "No subvolume mount pairs were detected. btrbk.conf contains no volume entries."
        ui_msgbox "Configuration Error" \
            "No btrfs subvolumes were detected for backup.
Please verify your btrfs layout and re-run Layer 2."
        return 1
    fi

    log_success "Created $BTRBK_CONF"

    # Validate BTRBK_CONF is an absolute path with no whitespace before
    # embedding it in the systemd unit.
    if [[ "$BTRBK_CONF" != /* ]]; then
        log_error "BTRBK_CONF must be an absolute path (got '$BTRBK_CONF')."
        return 1
    fi
    if [[ "$BTRBK_CONF" =~ [[:space:]] ]]; then
        log_error "BTRBK_CONF must not contain whitespace (got '$BTRBK_CONF')."
        return 1
    fi

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
    local systemd_mount="${backup_mount// /\\x20}"
    if ! cat <<EOF >"$override_conf"; then
[Unit]
RequiresMountsFor=$systemd_mount

[Service]
ExecStart=
ExecStart=/usr/bin/btrbk run --config $BTRBK_CONF
Nice=19
IOSchedulingClass=idle
EOF
        log_error "Failed to write $override_conf"
        return 1
    fi
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

        local rc=0
        timeout 3600 btrbk run --config "$BTRBK_CONF" >>"$LOG_FILE" 2>&1 || rc=$?
        if [[ $rc -eq 124 ]]; then
            log_error "Initial btrbk backup timed out after 1 hour."
            ui_msgbox "Backup Timed Out" \
                "The initial backup exceeded the 1-hour limit.
This may be normal for very large volumes. You can re-run it manually:
  sudo btrbk run --config $BTRBK_CONF"
        elif [[ $rc -ne 0 ]]; then
            log_warn "Initial btrbk backup finished with warnings or errors (exit $rc)."
            ui_msgbox "Backup Notice" \
                "Initial btrbk backup finished with warnings or errors.

Please check the log file for details:
  $LOG_FILE"
        else
            log_success "Initial btrbk backup completed successfully."
            ui_msgbox "Backup Succeeded" \
                "The initial btrbk OS clone completed successfully!

Destination: ${backup_mount}/OS_Backup
Details logged to: $LOG_FILE"
        fi
    else
        log_info "User skipped initial btrbk backup."
    fi

    # 8. Verify: check that btrbk.timer is active (unit_is_active btrbk.timer) and show success/failure via ui_msgbox.
    log_info "Step 8: Verifying btrbk.timer status..."
    if unit_is_active btrbk.timer; then
        # Also check btrbk.service last result for warnings.
        local _svc_result
        _svc_result=$(systemctl show -p Result --value btrbk.service 2>/dev/null)
        if [[ -n "$_svc_result" && "$_svc_result" != "success" ]]; then
            log_warn "btrbk.service last result is '$_svc_result' (expected 'success'). Check journal: journalctl -u btrbk.service"
        fi
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
