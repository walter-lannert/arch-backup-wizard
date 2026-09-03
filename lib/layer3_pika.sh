#!/usr/bin/env bash
# arch-backup-wizard/lib/layer3_pika.sh — Layer 3: Pika Backup Setup
#
# Sets up Layer 3: Pika Backup (Borg-based hourly home directory backups).
# 1. Installs pika-backup package (and borg dependency)
# 2. Creates Borg repository directory on backup drive: Personal/backup-<host>-<user>
# 3. Initializes Borg repository (unencrypted) if not already initialized
# 4. Prompts user for backup exclusion directories via ui_checklist
# 5. Displays guided setup instructions for configuring Pika Backup GUI
# 6. Optionally launches Pika Backup in background
# 7. Asks user to confirm completion
# 8. Validates Pika Backup configuration file exists

setup_layer3() {
    log_info "── Setting up Layer 3: Pika Backup (Borg home backups) ──"

    if [[ -z "${BACKUP_MOUNT:-}" ]]; then
        log_error "BACKUP_MOUNT is not set. Layer 3 requires a configured backup drive."
        ui_msgbox "Configuration Error" "Backup mount point is not set. Please configure the backup drive first."
        return 1
    fi

    local backup_mount="${BACKUP_MOUNT%/}"
    local target_user="${DETECTED_USER:-$(get_real_user)}"
    local target_host="${DETECTED_HOSTNAME:-$(cat /etc/hostname 2>/dev/null || uname -n)}"
    local target_home="${DETECTED_HOME:-$(get_real_home)}"

    # 1. Install packages: call install_layer_packages "3"
    log_info "Step 1: Installing Layer 3 packages..."
    if ! install_layer_packages "3"; then
        log_error "Failed to install Layer 3 packages."
        return 1
    fi
    log_success "Layer 3 packages installed successfully."

    # 2. Create the Borg repository directory:
    #    local repo_name="backup-${DETECTED_HOSTNAME}-${DETECTED_USER}"
    #    local repo_path="${BACKUP_MOUNT}/Personal/${repo_name}"
    local repo_name="backup-${target_host}-${target_user}"
    local repo_path="${backup_mount}/Personal/${repo_name}"

    log_info "Step 2: Ensuring Borg repository directory exists at $repo_path..."
    mkdir -p "${backup_mount}/Personal"
    chown "$target_user:" "${backup_mount}/Personal" 2>/dev/null || true
    mkdir -p "$repo_path"
    chown -R "$target_user:" "$repo_path" 2>/dev/null || true

    # 3. Initialize the Borg repository if it doesn't already exist:
    #    - Check if $repo_path/config exists (indicates initialized repo)
    #    - If not, run as the real user: run_as_user borg init --encryption=none "$repo_path"
    log_info "Step 3: Checking Borg repository initialization..."
    if [[ -f "$repo_path/config" ]]; then
        log_info "Borg repository already initialized at $repo_path"
    else
        log_info "Initializing Borg repository at $repo_path..."
        ui_infobox "Borg Repository" "Initializing Borg repository at:\n$repo_path..."
        if ! run_as_user borg init --encryption=none "$repo_path" >> "$LOG_FILE" 2>&1; then
            log_error "Failed to initialize Borg repository at $repo_path"
            ui_msgbox "Borg Init Error" \
"Failed to initialize Borg repository at:
  $repo_path

Check $LOG_FILE for details."
            return 1
        fi
        log_success "Initialized Borg repository at $repo_path"
    fi

    # 4. Show a smart exclusion checklist using ui_checklist
    log_info "Step 4: Prompting user for backup exclusions..."
    local raw_exclusions=""
    if ! raw_exclusions=$(ui_checklist "Backup Exclusions" \
        "Select directories to EXCLUDE from home backups:" \
        "Downloads"              "~/Downloads (temporary files)"              "on"  \
        "Games"                  "~/Games (large game installs)"              "on"  \
        "Backup"                 "~/Backup (backup drive mount, avoid loop)"  "on"  \
        ".cache"                 "~/.cache (regeneratable cache data)"        "on"  \
        "Trash"                  "Trash directories"                          "on"  \
        ".local/share/Steam"     "Steam game library"                         "on"  \
        ".local/share/lutris"    "Lutris game library"                        "off" \
        ".wine"                  "Wine prefixes"                              "off" \
        ".local/share/bottles"   "Bottles (Wine manager)"                     "off" \
        ".local/share/waydroid"  "Waydroid (Android emulator)"               "off" \
        ".config/borg"           "Borg cache (internal)"                      "on"  \
        "VirtualBox VMs"         "VirtualBox virtual machines"                "off"); then
        log_warn "Backup exclusion checklist was cancelled by user; continuing without exclusions."
        raw_exclusions=""
    fi

    local -a selected_exclusions=()
    if [[ -n "$raw_exclusions" ]]; then
        eval "selected_exclusions=($raw_exclusions)"
    fi
    log_info "Selected exclusions: ${selected_exclusions[*]:-(none)}"

    # 5. Show a multi-page guided setup dialog (ui_msgbox) explaining how to configure Pika Backup in the GUI
    log_info "Step 5: Showing guided Pika Backup GUI setup instructions..."
    local formatted_exclusions=""
    if [[ ${#selected_exclusions[@]} -eq 0 ]]; then
        formatted_exclusions="      (None)"
    else
        local current_bullet=""
        local count=0
        for excl in "${selected_exclusions[@]}"; do
            local display_path
            case "$excl" in
                /*|~/*) display_path="${excl}" ;;
                Trash)  display_path="Trash" ;;
                *)      display_path="~/${excl}" ;;
            esac

            if [[ -z "$current_bullet" ]]; then
                current_bullet="      • ${display_path}"
                count=1
            elif (( count < 3 )) && (( ${#current_bullet} + ${#display_path} + 2 <= 64 )); then
                current_bullet+=", ${display_path}"
                (( count++ ))
            else
                formatted_exclusions+="${current_bullet}"$'\n'
                current_bullet="      • ${display_path}"
                count=1
            fi
        done
        [[ -n "$current_bullet" ]] && formatted_exclusions+="${current_bullet}"
    fi

    local DLG_H=22
    ui_msgbox "Pika Backup Setup" \
"Pika Backup needs to be configured through its GUI.

Please follow these steps:

1. Open 'Pika Backup' from your application menu
2. Click 'Setup Backup' or the + button
3. Select 'Local Folder' and browse to:
   $repo_path
4. Pika will detect the existing Borg repository
5. Go to the Exclude tab and add these paths:
$formatted_exclusions
6. Set the schedule to 'Hourly'
7. Enable Pruning with:
   Hourly: 12, Daily: 7, Weekly: 4, Monthly: 6
8. Click 'Create Backup' to save"

    # 6. Ask if the user wants to launch Pika now (ui_yesno)
    log_info "Step 6: Asking user to launch Pika Backup..."
    if ui_yesno "Launch Pika Backup" "Would you like to launch Pika Backup now?"; then
        log_info "Launching Pika Backup in background for user $target_user..."
        run_as_user pika-backup >> "$LOG_FILE" 2>&1 &
    fi

    # 7. Ask the user to confirm when they've finished configuring Pika
    log_info "Step 7: Waiting for user confirmation of Pika Backup configuration..."
    if ui_yesno "Pika Backup Setup" "Have you finished configuring Pika Backup?"; then
        log_info "User confirmed Pika Backup configuration is complete."
    else
        log_warn "User indicated Pika Backup configuration is not complete."
    fi

    # 8. Validate: check if ~/.config/pika-backup/backup.json exists ($DETECTED_HOME/.config/pika-backup/backup.json)
    log_info "Step 8: Validating Pika Backup configuration..."
    local config_file="${target_home}/.config/pika-backup/backup.json"

    if [[ -f "$config_file" ]]; then
        log_success "Pika Backup configuration verified: $config_file"
        ui_msgbox "Pika Backup — Success" \
"Pika Backup has been successfully configured!

Configuration file detected:
  $config_file

Hourly home directory backups to Borg are now active."
    else
        log_warn "Pika Backup configuration file not found at: $config_file"
        ui_msgbox "Pika Backup — Warning" \
"Warning: Pika Backup configuration file was not detected:
  $config_file

You can complete the setup at any time by launching
Pika Backup from your desktop application menu."
    fi

    log_success "── Layer 3 setup completed ──"
    return 0
}

export -f setup_layer3
