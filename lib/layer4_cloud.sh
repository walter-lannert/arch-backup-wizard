#!/usr/bin/env bash
# arch-backup-wizard/lib/layer4_cloud.sh — Layer 4: Cloud Offsite Backups Setup
#
# Configures Layer 4: Cloud Offsite backups via rclone:
# 1. Installs required packages (rclone, pv, zstd, zenity)
# 2. Prompts user for cloud storage provider (Drive, OneDrive, Dropbox, B2)
# 3. Guides user through interactive rclone configuration and verifies connectivity
# 4. Prompts for cloud destination directory names
# 5. Generates the OS clone cloud upload script (~/.os_cloud_backup.sh)
# 6. Generates the bi-weekly nag reminder script (~/.os_clone_nag.sh)
# 7. Generates and enables Pika cloud sync user service and timer
# 8. Adds the nag script to user's shell startup file (idempotent)
# 9. Displays completion summary dialog

setup_layer4() {
    log_info "── Setting up Layer 4: Cloud Offsite (rclone) ──"

    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        log_error "BACKUP_MOUNT is not set. Layer 4 requires a configured backup drive."
        ui_msgbox "Configuration Error" "Backup mount point is not set. Please configure the backup drive first."
        return 1
    fi

    local backup_mount="${BACKUP_MOUNT%/}"
    local target_user
    target_user="$(effective_user)"
    local target_home
    target_home="$(effective_home)"
    local wizard_dir="${WIZARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # ── 1. Install packages ───────────────────────────────────────────────────
    log_info "Step 1: Installing Layer 4 packages..."
    ui_infobox "Layer 4 Packages" "Installing rclone, pv, zstd, and zenity...\nPlease wait."
    if ! install_layer_packages "4"; then
        log_error "Failed to install Layer 4 packages."
        return 1
    fi
    log_success "Layer 4 packages installed successfully."

    # ── 1.5 Generate Age Encryption Key ─────────────────────────────────────────
    log_info "Step 1.5: Setting up Age encryption for OS stream..."
    local age_key_dir="${target_home}/.config/arch-backup-wizard"
    local age_key_file="${age_key_dir}/cloud_os.key"

    run_as_user mkdir -p "$age_key_dir" || return 1

    if [[ ! -f "$age_key_file" ]]; then
        run_as_user age-keygen -o "$age_key_file" >/dev/null 2>&1
        run_as_user chmod 600 "$age_key_file"
        log_info "Generated new age key at $age_key_file"
    else
        log_info "Using existing age key at $age_key_file"
    fi

    local age_pubkey
    age_pubkey=$(grep -oP 'public key: \K\w+' "$age_key_file")
    export AGE_PUBKEY="$age_pubkey"
    export AGE_KEYFILE="$age_key_file"

    ui_msgbox "Encryption Key Generated" \
        "A new Age encryption key has been generated to encrypt your OS clones before they are uploaded to the cloud.

PUBLIC KEY:
$age_pubkey

The private key is currently saved at:
$age_key_file

[!] CRITICAL WARNING [!]
If your computer is destroyed or stolen, you WILL need this private key to decrypt your cloud backup.

You MUST back up this private key to an external USB drive, another computer, or a secure Password Manager RIGHT NOW."

    while true; do
        if ui_yesno "Confirm Key Backup" \
            "Have you successfully backed up your Age private key to an external USB drive or password manager?

Without this key, your cloud backups are completely unrecoverable in a bare-metal disaster."; then
            break
        else
            ui_msgbox "Action Required" "Please back up the file:\n$age_key_file\n\nTake your time, then press OK to verify again."
        fi
    done

    # ── 2. Cloud provider selection menu ──────────────────────────────────────
    log_info "Step 2: Selecting cloud storage provider..."
    local cloud_type
    if ! cloud_type=$(ui_menu "Cloud Provider" \
        "Select your cloud storage provider:" \
        "drive" "Google Drive" \
        "onedrive" "Microsoft OneDrive" \
        "dropbox" "Dropbox" \
        "b2" "Backblaze B2"); then
        log_warn "Cloud provider selection cancelled by user."
        return 1
    fi
    cloud_type="${cloud_type//\"/}"

    local provider_label="$cloud_type"
    case "$cloud_type" in
    drive) provider_label="Google Drive" ;;
    onedrive) provider_label="Microsoft OneDrive" ;;
    dropbox) provider_label="Dropbox" ;;
    b2) provider_label="Backblaze B2" ;;
    esac
    log_info "Selected cloud provider: $provider_label ($cloud_type)"

    # ── 3. Guide user through rclone configuration ────────────────────────────
    log_info "Step 3: Guiding user through rclone configuration..."
    ui_msgbox "Rclone Configuration" \
        "You will now configure rclone to connect to ${provider_label}.

Next, an interactive 'rclone config' session will open in this terminal.

Recommended steps in rclone config:
  1. Enter 'n' for a new remote
  2. Use the remote name you specify in the next step
  3. Select '${cloud_type}' when prompted for storage type
  4. Follow the authentication prompts (web browser login)
  5. Accept defaults for advanced options unless needed
  6. Confirm and quit 'q' when finished

Press OK to continue."

    local input_remote
    input_remote=$(ui_inputbox "Rclone Remote" \
        "Enter the name for your rclone remote:" \
        "cloud") || input_remote="cloud"
    input_remote="${input_remote:-cloud}"
    input_remote="${input_remote%:}"
    input_remote="${input_remote// /_}"
    [[ -z "$input_remote" ]] && input_remote="cloud"
    local rclone_remote="${input_remote}:"

    log_info "Configured rclone remote target: $rclone_remote"

    while true; do
        clear
        log_info "Launching interactive rclone config for user $target_user..."
        run_as_user rclone config

        log_info "Verifying connectivity for remote '$rclone_remote'..."
        ui_infobox "Verifying Remote" "Testing connection to $rclone_remote...\nPlease wait."

        if run_as_user rclone lsd "$rclone_remote" >>"$LOG_FILE" 2>&1; then
            log_success "Connectivity to remote '$rclone_remote' verified successfully."
            break
        else
            log_warn "Failed to connect to rclone remote '$rclone_remote'."
            if ui_yesno "Connection Failed" \
                "Failed to connect to rclone remote '$rclone_remote'.

The remote may not be configured properly or authentication failed.
Check $LOG_FILE for details.

Would you like to re-run 'rclone config' to retry?
(Select 'No' to skip verification and proceed anyway)"; then
                log_info "User chose to retry rclone configuration."
                local retry_remote
                retry_remote=$(ui_inputbox "Rclone Remote" \
                    "Confirm or enter your rclone remote name:" \
                    "${rclone_remote%:}") || retry_remote="${rclone_remote%:}"
                retry_remote="${retry_remote:-${rclone_remote%:}}"
                retry_remote="${retry_remote%:}"
                retry_remote="${retry_remote// /_}"
                rclone_remote="${retry_remote}:"
            else
                log_warn "User chose to skip rclone connectivity verification."
                break
            fi
        fi
    done

    # ── 4. Ask for cloud destination folder names ─────────────────────────────
    log_info "Step 4: Prompting for cloud destination folder names..."
    local distro_name="${DETECTED_DISTRO:-Arch}"
    distro_name="${distro_name// /_}"

    local default_os_dir="${distro_name}_BareMetal_Clones"
    local cloud_os_dir="$default_os_dir"
    while true; do
        cloud_os_dir=$(ui_inputbox "OS Clones Folder" \
            "Enter cloud destination folder for bare-metal OS clones (a-z, 0-9, -, _, /):" \
            "$cloud_os_dir") || cloud_os_dir="$default_os_dir"
        cloud_os_dir="${cloud_os_dir:-$default_os_dir}"
        if [[ "$cloud_os_dir" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
            break
        else
            ui_msgbox "Error" "Invalid folder name. Only alphanumeric, slashes, dashes, and underscores are allowed."
        fi
    done
    cloud_os_dir="${cloud_os_dir#/}"
    cloud_os_dir="${cloud_os_dir%/}"

    local default_pika_dir="${distro_name}_Pika_Backup"
    local cloud_pika_dir="$default_pika_dir"
    while true; do
        cloud_pika_dir=$(ui_inputbox "Pika Backup Folder" \
            "Enter cloud destination folder for Pika backups (a-z, 0-9, -, _, /):" \
            "$cloud_pika_dir") || cloud_pika_dir="$default_pika_dir"
        cloud_pika_dir="${cloud_pika_dir:-$default_pika_dir}"
        if [[ "$cloud_pika_dir" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
            break
        else
            ui_msgbox "Error" "Invalid folder name. Only alphanumeric, slashes, dashes, and underscores are allowed."
        fi
    done
    cloud_pika_dir="${cloud_pika_dir#/}"
    cloud_pika_dir="${cloud_pika_dir%/}"

    log_info "Cloud destination folders: OS='$cloud_os_dir', Pika='$cloud_pika_dir'"

    # ── 5. Generate OS cloud backup script ─────────────────────────────────────
    log_info "Step 5: Generating OS cloud backup script..."
    export BACKUP_MOUNT="$backup_mount"
    export CLOUD_REMOTE="$rclone_remote"
    export CLOUD_OS_DIR="$cloud_os_dir"

    local os_backup_script="${target_home}/.os_cloud_backup.sh"
    backup_file "$os_backup_script" >/dev/null || return 1

    template_render "$wizard_dir/templates/os-cloud-backup.sh" "$os_backup_script"
    chmod 700 "$os_backup_script"
    chown "$target_user:" "$os_backup_script"
    record_manifest "$os_backup_script"
    log_success "Generated OS cloud backup script at $os_backup_script"

    # ── 6. Generate nag script ────────────────────────────────────────────────
    log_info "Step 6: Generating OS clone nag script..."
    local term_cmd="${DETECTED_TERMINAL_CMD:-}"
    if [[ -z "$term_cmd" ]]; then
        detect_terminal
        term_cmd="${DETECTED_TERMINAL_CMD:-xterm -e}"
    fi

    export DETECTED_HOME="$target_home"
    export DETECTED_TERMINAL_CMD="$term_cmd"

    local os_nag_script="${target_home}/.os_clone_nag.sh"
    backup_file "$os_nag_script" >/dev/null || return 1

    template_render "$wizard_dir/templates/os-clone-nag.sh" "$os_nag_script"
    chmod 700 "$os_nag_script"
    chown "$target_user:" "$os_nag_script"
    record_manifest "$os_nag_script"
    log_success "Generated OS clone nag script at $os_nag_script"

    # ── 7. Generate and install Pika cloud sync service and timer ─────────────
    log_info "Step 7: Generating and installing Pika cloud sync system units (running as user)..."
    export BACKUP_MOUNT="$backup_mount"
    export CLOUD_REMOTE="$rclone_remote"
    export CLOUD_PIKA_DIR="$cloud_pika_dir"

    local systemd_dir="/etc/systemd/system"
    mkdir -p "$systemd_dir"

    local service_file="${systemd_dir}/pika-cloud-sync.service"
    local timer_file="${systemd_dir}/pika-cloud-sync.timer"

    backup_file "$service_file" >/dev/null || return 1
    template_render "$wizard_dir/templates/pika-cloud-sync.service" "$service_file"
    record_manifest "$service_file"

    backup_file "$timer_file" >/dev/null || return 1
    template_render "$wizard_dir/templates/pika-cloud-sync.timer" "$timer_file"
    record_manifest "$timer_file"

    log_success "Installed systemd units: $service_file and $timer_file"

    log_info "Reloading systemd daemon and enabling pika-cloud-sync.timer..."
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    if systemctl enable --now pika-cloud-sync.timer >>"$LOG_FILE" 2>&1; then
        log_success "Enabled and started pika-cloud-sync.timer"
    else
        log_error "Failed to enable pika-cloud-sync.timer"
    fi

    # ── 8. Add nag script to user's shell startup ─────────────────────────────
    log_info "Step 8: Adding nag script to user's shell startup..."
    local shell_bin
    shell_bin=$(basename "${DETECTED_SHELL:-bash}")
    local rc_file=""
    local nag_line=""

    case "$shell_bin" in
    zsh)
        rc_file="${target_home}/.zshrc"
        nag_line='[[ -o interactive ]] && [ -f ~/.os_clone_nag.sh ] && bash ~/.os_clone_nag.sh &'
        ;;
    fish)
        rc_file="${target_home}/.config/fish/config.fish"
        nag_line='status is-interactive; and test -f ~/.os_clone_nag.sh; and bash ~/.os_clone_nag.sh &'
        ;;
    bash | *)
        rc_file="${target_home}/.bashrc"
        nag_line='case $- in *i*) [ -f ~/.os_clone_nag.sh ] && bash ~/.os_clone_nag.sh & ;; esac'
        ;;
    esac

    run_as_user mkdir -p "$(dirname "$rc_file")" || {
        log_error "Failed to create $(dirname "$rc_file") as user $target_user"
        return 1
    }
    if [[ -f "$rc_file" ]] && grep -Fq "Arch Backup Wizard OS Clone Nag" "$rc_file"; then
        log_info "Nag script already configured in $rc_file"
    else
        backup_file "$rc_file" >/dev/null || return 1
        # shellcheck disable=SC2016
        run_as_user bash -c 'cat >> "$1"' -- "$rc_file" <<EOF

# Arch Backup Wizard OS Clone Nag BEGIN
$nag_line
# Arch Backup Wizard OS Clone Nag END
EOF
        # chown is no longer needed since it's written as the user
        log_success "Added nag script invocation to $rc_file"
    fi

    # ── 9. Completion summary dialog ────────────────────────────────────────
    log_info "Step 9: Showing completion summary..."
    ui_msgbox "Layer 4 Setup Complete" \
        "Layer 4 (Cloud Offsite) has been successfully configured!

Configuration Summary:
• Provider:           ${provider_label} (${cloud_type})
• Rclone Remote:      ${rclone_remote}
• OS Clones Folder:   ${rclone_remote}${cloud_os_dir}
• Pika Backup Folder: ${rclone_remote}${cloud_pika_dir}

Installed Components:
• OS Cloud Backup:
  ${os_backup_script}
• Bi-weekly Nag Script:
  ${os_nag_script} (added to $(basename "$rc_file"))
• Pika Cloud Sync System Units:
  ${timer_file} (weekly sync enabled)

Your offsite cloud backup pipeline is ready."

    log_success "── Layer 4 setup completed ──"
    return 0
}
