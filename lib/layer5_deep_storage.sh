#!/usr/bin/env bash
# arch-backup-wizard/lib/layer5_deep_storage.sh — Layer 5: Deep Storage setup
#
# Sets up a local archive directory on the backup drive that is intentionally
# excluded from cloud sync (Layer 4) for sensitive or large files.

setup_layer5() {
    log_info "Setting up Layer 5: Deep Storage..."

    if [[ -z "${BACKUP_MOUNT}" ]]; then
        log_error "Backup mount point is not set. Please select or configure a backup drive first."
        ui_msgbox "Configuration Error" "Backup mount point is not set. Please configure the backup drive first."
        return 1
    fi

    # Must be an absolute path
    if [[ "${BACKUP_MOUNT}" != /* ]]; then
        log_error "BACKUP_MOUNT must be an absolute path, got: ${BACKUP_MOUNT}"
        return 1
    fi

    # Reject the filesystem root — creating /Deep Storage defeats the purpose.
    # Normalise first so /./, /../, ///, etc. are all caught.
    local _norm
    _norm="$(realpath -m -- "${BACKUP_MOUNT}" 2>/dev/null)" || _norm="${BACKUP_MOUNT}"
    if [[ "${_norm%/}" == "" || "${_norm%/}" == "/" ]]; then
        log_error "BACKUP_MOUNT must not be the filesystem root '/'. Select a specific backup partition."
        ui_msgbox "Configuration Error" "The backup mount point cannot be the root filesystem. Please select a dedicated backup partition."
        return 1
    fi

    # Reject well-known virtual / special filesystems where a "Deep Storage"
    # directory is meaningless or dangerous.
    local _rejected_prefixes=(
        "/dev" "/proc" "/sys" "/run" "/boot/efi"
    )
    local _rp
    _rp="$(realpath -m -- "${BACKUP_MOUNT}" 2>/dev/null)" || _rp="${BACKUP_MOUNT}"
    local _rp_noslash="${_rp%/}"
    for _prefix in "${_rejected_prefixes[@]}"; do
        if [[ "${_rp_noslash}" == "${_prefix}" || "${_rp_noslash}" == "${_prefix}"/* ]]; then
            log_error "BACKUP_MOUNT '${BACKUP_MOUNT}' resolves to a special/virtual filesystem (${_prefix})."
            ui_msgbox "Configuration Error" "The selected path is on a virtual filesystem. Please select a real backup partition."
            return 1
        fi
    done

    # Must exist and be a directory (not a file, not a dangling symlink)
    if [[ ! -d "${BACKUP_MOUNT}" ]]; then
        log_error "Backup mount point '${BACKUP_MOUNT}' does not exist or is not a directory."
        ui_msgbox "Configuration Error" "The backup drive at ${BACKUP_MOUNT} is not available. Please reconnect it."
        return 1
    fi

    # Must be a real mount point (guards against unmounted-drive scenario)
    if ! command -v mountpoint &>/dev/null; then
        log_warn "mountpoint(1) not found; skipping mount-point verification."
    elif ! mountpoint -q "$(realpath -m -- "${BACKUP_MOUNT}" 2>/dev/null || echo "${BACKUP_MOUNT}")" 2>/dev/null; then
        log_error "BACKUP_MOUNT '${BACKUP_MOUNT}' is not a mount point. The backup drive may be disconnected."
        ui_msgbox "Configuration Error" "The backup drive is not mounted. Please reconnect and re-select it."
        return 1
    fi

    local deep_storage_dir="${BACKUP_MOUNT%/}/Deep Storage"
    if [[ -L "$deep_storage_dir" ]]; then
        log_error "Deep Storage path '${deep_storage_dir}' is a symlink. Refusing to proceed."
        ui_msgbox "Configuration Error" "The Deep Storage path is a symbolic link. Remove it and re-run."
        return 1
    fi
    # Re-verify the mount is still live immediately before mutating the tree.
    if command -v mountpoint &>/dev/null; then
        local _rp
        _rp="$(realpath -m -- "${BACKUP_MOUNT}" 2>/dev/null)" || _rp="${BACKUP_MOUNT}"
        if ! mountpoint -q "${_rp}" 2>/dev/null; then
            log_error "Backup drive was unmounted during setup. Aborting."
            ui_msgbox "Configuration Error" "The backup drive was disconnected during setup. Please reconnect it and re-run."
            return 1
        fi
    fi

    if [[ ! -w "${BACKUP_MOUNT}" ]]; then
        log_error "Backup mount point '${BACKUP_MOUNT}' is not writable (read-only mount?)."
        ui_msgbox "Configuration Error" "The backup drive is mounted read-only. Remount it read-write and re-run."
        return 1
    fi

    # Acquire an exclusive lock to prevent concurrent setup invocations.
    # NOTE: This lock file is intentionally left on the backup drive after
    #       setup completes.  Removing it would reintroduce a TOCTOU race.
    #       It is a zero-byte (or near-zero-byte) hidden file and is safe to
    #       ignore in backup/sync tooling.
    local _lockfile="${BACKUP_MOUNT%/}/.deep_storage_setup.lock"
    if ! touch "$_lockfile" 2>/dev/null; then
        log_error "Cannot create lock file '${_lockfile}'."
        return 1
    fi
    # exec is a special builtin: a redirection failure would exit the shell
    # before any || / if-! guard could fire.  The touch() call above already
    # validated that the path is creatable and writable, so this is safe.
    exec 9<>"$_lockfile" # shellcheck disable=SC2317
    if ! command -v flock &>/dev/null; then
        log_warn "flock(1) not found; falling back to mkdir-based lock."
        local _lockdir="${BACKUP_MOUNT%/}/.deep_storage_setup.lock.d"
        if ! mkdir "$_lockdir" 2>/dev/null; then
            log_error "Another instance of Layer 5 setup is already running."
            ui_msgbox "Busy" "Another setup is in progress. Please wait."
            exec 9>&-
            return 1
        fi
        # Clean up the lock directory on exit.
        trap 'rmdir "$_lockdir" 2>/dev/null' RETURN
    elif ! flock -n 9; then
        log_error "Another instance of Layer 5 setup is already running."
        ui_msgbox "Busy" "Another setup is in progress. Please wait."
        return 1
    fi

    local _install_err
    if ! _install_err="$(install -d -m 0700 "$deep_storage_dir" 2>&1)"; then
        log_error "Failed to create $deep_storage_dir: ${_install_err}"
        return 1
    fi
    # Post-creation: confirm the path is a real directory, not a symlink
    if [[ -L "$deep_storage_dir" ]]; then
        log_error "Deep Storage path became a symlink during creation. Removing."
        rm -f "$deep_storage_dir"
        return 1
    fi

    # Post-creation sanity: confirm the new inode actually lives on the
    # expected device (guards against the narrow window where the drive
    # was swapped for a different block device between the two checks).
    local expected_dev actual_dev
    expected_dev="$(stat -c '%d' "${BACKUP_MOUNT}" 2>/dev/null)" || {
        log_error "stat failed on BACKUP_MOUNT; cannot verify device identity."
        return 1
    }
    actual_dev="$(stat -c '%d' "$deep_storage_dir" 2>/dev/null)" || {
        log_error "stat failed on Deep Storage dir; cannot verify device identity."
        rmdir "$deep_storage_dir" 2>/dev/null
        return 1
    }
    if [[ "$expected_dev" != "$actual_dev" ]]; then
        log_error "Deep Storage directory landed on a different device than the backup mount. Removing."
        if ! rmdir "$deep_storage_dir" 2>/dev/null; then
            log_warn "Could not remove orphaned '${deep_storage_dir}' (non-empty?). Manual cleanup required."
        fi
        ui_msgbox "Configuration Error" "The backup drive changed during setup. Please re-select it and re-run."
        return 1
    fi

    local target_user
    target_user="$(effective_user 2>/dev/null)"
    target_user="${target_user:-}"
    # Reject multi-line or obviously malformed values
    if [[ "$target_user" == *$'\n'* || "$target_user" == *' '* \
          || "$target_user" == *';'* || "$target_user" == *'|'* \
          || "$target_user" == *'&'* || "$target_user" == *'$'* \
          || "$target_user" == *'`'* || "$target_user" == *'('* \
          || "$target_user" == *')'* || "$target_user" == *'>'* \
          || "$target_user" == *'<'* || "$target_user" == *'*'* \
          || "$target_user" == *'?'* || "$target_user" == *'['* \
          || "$target_user" == *']'* || "$target_user" == *'\\'* ]]; then
        log_warn "effective_user returned unexpected value: '${target_user}'. Skipping chown."
        target_user=""
    fi
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        if ! chown "$target_user" "$deep_storage_dir" 2>/dev/null; then
            log_warn "Could not chown '${deep_storage_dir}' to '${target_user}' (may be a non-POSIX filesystem or insufficient privileges)."
        fi
    fi

    # Verify that the 0700 mode was actually applied (non-POSIX FS may ignore it).
    local _actual_mode
    _actual_mode="$(stat -c '%a' "$deep_storage_dir" 2>/dev/null)" || _actual_mode=""
    if [[ "$_actual_mode" != "700" ]]; then
        log_warn "WARNING: '${deep_storage_dir}' has mode ${_actual_mode:-unknown}, not 0700."
        log_warn "The underlying filesystem may not enforce Unix permissions (e.g. exFAT, FAT32, NTFS)."
        log_warn "Files in this directory may be readable by other local users."
    fi

    if ! ui_msgbox "Layer 5: Deep Storage" \
        "Deep Storage is available at:
${deep_storage_dir}

This is a local-only archive for:
- Personal documents and photos
- Old cloud data exports
- Anything you want preserved but NOT uploaded

This directory is intentionally excluded from
cloud sync (Layer 4) to keep sensitive or large
files under your physical control only.

Simply copy files into this directory manually
whenever you need to archive something."
    then
        log_warn "Could not display GUI confirmation; verify Layer 5 status in the log."
    fi

    log_success "Layer 5: Deep Storage directory created at ${deep_storage_dir}"
}
