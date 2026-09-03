#!/usr/bin/env bash
# arch-backup-wizard/lib/layer1_snapper.sh — Layer 1: Snapper BTRFS Snapshots
#
# Sets up Snapper for root BTRFS snapshots with pacman hook integration (snap-pac)
# and bootloader menu integration.

# ── Main setup entrypoint ─────────────────────────────────────────────────────

setup_layer1() {
    log_info "══════ Setting up Layer 1: Snapper ══════"

    # ── 1. Install packages ───────────────────────────────────────────────────
    log_info "Step 1: Installing Layer 1 packages..."
    ui_infobox "Layer 1" "Installing packages for Snapper and bootloader integration..."
    if ! install_layer_packages "1"; then
        die "Failed to install Layer 1 packages."
    fi
    log_success "Layer 1 packages installed successfully."

    # ── 2. Handle .snapshots subvolume ────────────────────────────────────────
    log_info "Step 2: Handling .snapshots subvolume..."
    if [[ "${DETECTED_SNAPPER_CONFIG_EXISTS:-false}" == "true" ]] || [[ -f /etc/snapper/configs/root ]]; then
        log_info "Snapper root configuration already exists. Skipping subvolume creation."
    else
        # Check if /.snapshots exists as a BTRFS subvolume already (common on CachyOS/EndeavourOS)
        if mountpoint -q /.snapshots 2>/dev/null || findmnt -n /.snapshots &>/dev/null; then
            log_info "Unmounting pre-existing /.snapshots subvolume mount..."
            umount /.snapshots >> "$LOG_FILE" 2>&1 || die "Failed to unmount /.snapshots"
        fi

        # Snapper create-config fails if the directory /.snapshots already exists on the root filesystem.
        # If /.snapshots exists (as directory mountpoint or pre-created subvolume), remove it first.
        if [[ -e /.snapshots ]]; then
            if btrfs subvolume show /.snapshots &>/dev/null; then
                log_info "Deleting existing unmounted /.snapshots subvolume on root..."
                btrfs subvolume delete /.snapshots >> "$LOG_FILE" 2>&1 || die "Failed to delete /.snapshots subvolume"
            elif [[ -d /.snapshots ]]; then
                log_info "Removing /.snapshots mount directory..."
                rmdir /.snapshots >> "$LOG_FILE" 2>&1 || {
                    log_warn "/.snapshots directory is not empty; backing it up to /.snapshots.wizard.bak"
                    mv /.snapshots "/.snapshots.wizard.bak.$(date +%s)" >> "$LOG_FILE" 2>&1 || die "Failed to remove /.snapshots directory"
                }
            fi
        fi

        # Run snapper create-config
        log_info "Creating Snapper root config with: snapper -c root create-config /"
        ui_infobox "Snapper Setup" "Creating Snapper configuration for /..."
        snapper -c root create-config / >> "$LOG_FILE" 2>&1 || die "snapper -c root create-config / failed. Check $LOG_FILE for details."

        # Snapper creates its own .snapshots subvolume which conflicts with pre-existing ones.
        # Check if a top-level @.snapshots or @snapshots subvolume exists
        local existing_subvol=""
        local candidate
        for candidate in "@snapshots" "@.snapshots"; do
            if btrfs subvolume list / 2>/dev/null | awk '{print $NF}' | grep -qx "$candidate"; then
                existing_subvol="$candidate"
                break
            fi
        done

        # Also check /etc/fstab for pre-existing @snapshots / @.snapshots entry
        if [[ -z "$existing_subvol" ]] && grep -qE '[[:space:]]+/\.snapshots[[:space:]]+' /etc/fstab 2>/dev/null; then
            local fstab_subvol
            fstab_subvol=$(grep -E '[[:space:]]+/\.snapshots[[:space:]]+' /etc/fstab | grep -oP 'subvol=\K[^, \t]+' || echo "")
            fstab_subvol="${fstab_subvol#/}"
            if [[ "$fstab_subvol" == "@snapshots" || "$fstab_subvol" == "@.snapshots" ]]; then
                existing_subvol="$fstab_subvol"
            fi
        fi

        if [[ -n "$existing_subvol" ]]; then
            log_info "Top-level subvolume '$existing_subvol' detected. Deleting Snapper auto-created subvolume and mounting '$existing_subvol'..."
            btrfs subvolume delete /.snapshots >> "$LOG_FILE" 2>&1 || die "Failed to delete Snapper auto-created /.snapshots subvolume"
            mkdir -p /.snapshots

            if grep -qE '[[:space:]]+/\.snapshots[[:space:]]+' /etc/fstab 2>/dev/null; then
                log_info "Mounting /.snapshots from /etc/fstab..."
                mount /.snapshots >> "$LOG_FILE" 2>&1 || die "Failed to mount /.snapshots from /etc/fstab"
            else
                local root_uuid="${DETECTED_ROOT_UUID:-$(findmnt -n -o UUID / 2>/dev/null || echo "")}"
                log_info "Adding $existing_subvol mount entry to /etc/fstab (UUID=$root_uuid)..."
                backup_file /etc/fstab
                printf '\nUUID=%s /.snapshots btrfs subvol=%s,defaults,noatime,compress=zstd 0 0\n' \
                    "$root_uuid" "$existing_subvol" >> /etc/fstab
                mount /.snapshots >> "$LOG_FILE" 2>&1 || die "Failed to mount /.snapshots"
            fi
            chmod 750 /.snapshots
            log_success "Mounted existing subvolume $existing_subvol at /.snapshots"
        else
            log_info "Using Snapper auto-created /.snapshots subvolume."
            chmod 750 /.snapshots
        fi
    fi

    # ── 3. Write Snapper config /etc/snapper/configs/root ──────────────────────
    log_info "Step 3: Writing /etc/snapper/configs/root..."
    mkdir -p /etc/snapper/configs
    backup_file /etc/snapper/configs/root

    cat > /etc/snapper/configs/root <<'EOF'
# subvolume to snapshot
SUBVOLUME="/"

# filesystem type
FSTYPE="btrfs"

# btrfs qgroup for space aware cleanup algorithms
QGROUP=""

# fraction or absolute size of the filesystems space the snapshots may use
SPACE_LIMIT="0.5"

# fraction or absolute size of the filesystems space that should be free
FREE_LIMIT="0.2"

# users and groups allowed to work with config
ALLOW_USERS=""
ALLOW_GROUPS=""

# sync users and groups from ALLOW_USERS and ALLOW_GROUPS to .snapshots directory
SYNC_ACL="no"

# start comparing pre- and post-snapshot in background after creating post-snapshot
BACKGROUND_COMPARISON="yes"

# run daily number cleanup
NUMBER_CLEANUP="yes"

# limit for number cleanup
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="15"

# create hourly snapshots
TIMELINE_CREATE="no"

# cleanup hourly snapshots after some time
TIMELINE_CLEANUP="yes"

# limits for timeline cleanup
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"

# cleanup empty pre-post-pairs
EMPTY_PRE_POST_CLEANUP="yes"

# limits for empty pre-post-pair cleanup
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
    log_success "Wrote Snapper configuration to /etc/snapper/configs/root"

    # Ensure /etc/conf.d/snapper includes root config if the file exists
    if [[ -f /etc/conf.d/snapper ]]; then
        if ! grep -qE '^SNAPPER_CONFIGS=.*root' /etc/conf.d/snapper; then
            backup_file /etc/conf.d/snapper
            if grep -q '^SNAPPER_CONFIGS=' /etc/conf.d/snapper; then
                sed -i 's/^SNAPPER_CONFIGS="\(.*\)"/SNAPPER_CONFIGS="\1 root"/' /etc/conf.d/snapper
                sed -i 's/^SNAPPER_CONFIGS=""/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
            else
                echo 'SNAPPER_CONFIGS="root"' >> /etc/conf.d/snapper
            fi
            log_info "Updated /etc/conf.d/snapper with root config."
        fi
    fi

    # ── 4. Enable snapper-cleanup.timer ───────────────────────────────────────
    log_info "Step 4: Enabling snapper-cleanup.timer..."
    systemctl enable --now snapper-cleanup.timer >> "$LOG_FILE" 2>&1 || die "Failed to enable snapper-cleanup.timer"
    log_success "snapper-cleanup.timer enabled and started."

    # Ensure timeline timer is disabled since TIMELINE_CREATE="no"
    if unit_is_active snapper-timeline.timer || unit_is_enabled snapper-timeline.timer; then
        log_info "Disabling snapper-timeline.timer (TIMELINE_CREATE is set to no)..."
        systemctl disable --now snapper-timeline.timer >> "$LOG_FILE" 2>&1 || true
    fi

    # ── 5. Bootloader-specific setup ──────────────────────────────────────────
    log_info "Step 5: Configuring bootloader integration for '$DETECTED_BOOTLOADER'..."
    case "$DETECTED_BOOTLOADER" in
        grub)
            log_info "Enabling grub-btrfsd service..."
            systemctl enable --now grub-btrfsd >> "$LOG_FILE" 2>&1 || die "Failed to enable grub-btrfsd service"
            log_success "grub-btrfsd service enabled and started."
            ;;
        limine)
            log_info "Limine bootloader detected; showing limine-snapper-sync info..."
            ui_msgbox "Limine Bootloader Integration" \
"Limine snapshot integration is active.

limine-snapper-sync is installed. Whenever a snapshot is created by Snapper or pacman, it will automatically appear in your Limine boot menu."
            ;;
        systemd-boot)
            log_info "systemd-boot detected; showing manual rollback notice..."
            ui_msgbox "systemd-boot Notice" \
"Notice for systemd-boot:

systemd-boot does not natively support booting directly into BTRFS snapshots from the boot menu.

However, snapshots are still automatically created on every pacman transaction (via snap-pac) and can be rolled back manually using Snapper or a live USB."
            ;;
        *)
            log_warn "Unknown or unsupported bootloader: $DETECTED_BOOTLOADER"
            ui_msgbox "Bootloader Notice" \
"Bootloader '$DETECTED_BOOTLOADER' does not have automated boot menu snapshot integration.

Snapshots will still be taken before and after package changes and can be restored manually using Snapper."
            ;;
    esac

    # ── 6. Verify ─────────────────────────────────────────────────────────────
    log_info "Step 6: Verifying Snapper setup..."
    local snapper_out
    if snapper_out=$(snapper list 2>&1); then
        log_success "Snapper verification succeeded."
        log_info "Verification output:\n$snapper_out"
        ui_msgbox "Layer 1 Setup Succeeded" \
"Layer 1 (Snapper) setup completed successfully!

Snapper is active and configured for pacman hook snapshots.

Current snapshots:
$snapper_out"
    else
        local exit_code=$?
        log_error "Snapper verification failed with exit code $exit_code: $snapper_out"
        ui_msgbox "Layer 1 Verification Failed" \
"Snapper verification failed!

Command 'snapper list' returned exit code $exit_code.

Error output:
$snapper_out

Please check $LOG_FILE for details."
        return 1
    fi

    log_success "══════ Layer 1: Snapper setup complete ══════"
}

export -f setup_layer1
