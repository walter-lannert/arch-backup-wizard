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

    local deep_storage_dir="${BACKUP_MOUNT}/Deep Storage"

    mkdir -p "$deep_storage_dir" || {
        log_error "Failed to create $deep_storage_dir"
        return 1
    }

    local target_user
    target_user="$(effective_user)"
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        chown "$target_user:" "$deep_storage_dir" 2>/dev/null || true
    fi

    ui_msgbox "Layer 5: Deep Storage" \
        "Deep Storage has been created at:
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
