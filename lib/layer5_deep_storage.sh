#!/usr/bin/env bash
# arch-backup-wizard/lib/layer5_deep_storage.sh — Layer 5: Deep Storage setup
#
# Sets up a local archive directory on the backup drive that is intentionally
# excluded from cloud sync (Layer 4) for sensitive or large files.

setup_layer5() {
    log_info "Setting up Layer 5: Deep Storage..."

    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        log_error "Backup mount point is not set. Please select or configure a backup drive first."
        ui_msgbox "Configuration Error" "Backup mount point is not set. Please configure the backup drive first."
        return 1
    fi

    # Must be an absolute path
    if [[ "${BACKUP_MOUNT}" != /* ]]; then
        log_error "BACKUP_MOUNT must be an absolute path, got: ${BACKUP_MOUNT}"
        return 1
    fi

    # Must exist and be a directory (not a file, not a dangling symlink)
    if [[ ! -d "${BACKUP_MOUNT}" ]]; then
        log_error "Backup mount point '${BACKUP_MOUNT}' does not exist or is not a directory."
        ui_msgbox "Configuration Error" "The backup drive at ${BACKUP_MOUNT} is not available. Please reconnect it."
        return 1
    fi

    # Must be a real mount point (guards against unmounted-drive scenario)
    if ! mountpoint -q "${BACKUP_MOUNT}" 2>/dev/null; then
        log_error "BACKUP_MOUNT '${BACKUP_MOUNT}' is not a mount point. The backup drive may be disconnected."
        ui_msgbox "Configuration Error" "The backup drive is not mounted. Please reconnect and re-select it."
        return 1
    fi

    local deep_storage_dir="${BACKUP_MOUNT%/}/Deep Storage"

    mkdir -p "$deep_storage_dir" || {
        log_error "Failed to create $deep_storage_dir"
        return 1
    }

    chmod 0755 "$deep_storage_dir" 2>/dev/null || \
        log_warn "Could not set permissions on '${deep_storage_dir}'."

    local target_user
    target_user="$(effective_user 2>/dev/null)" || target_user=""
    # Reject multi-line or obviously malformed values
    if [[ "$target_user" == *$'\n'* || "$target_user" == *' '* ]]; then
        log_warn "effective_user returned unexpected value: '${target_user}'. Skipping chown."
        target_user=""
    fi
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        if ! chown "$target_user" "$deep_storage_dir" 2>/dev/null; then
            log_warn "Could not chown '${deep_storage_dir}' to '${target_user}' (may be a non-POSIX filesystem or insufficient privileges)."
        fi
    fi

    ui_msgbox "Layer 5: Deep Storage" \
        "Deep Storage is available at:
${deep_storage_dir}

This is a local-only archive for:
• Personal documents and photos
• Old cloud data exports
• Anything you want preserved but NOT uploaded

This directory is intentionally excluded from
cloud sync (Layer 4) to keep sensitive or large
files under your physical control only.

Simply copy files into this directory manually
whenever you need to archive something."

    log_success "Layer 5: Deep Storage directory created at ${deep_storage_dir}"
}
