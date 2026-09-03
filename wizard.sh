#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Arch Backup Wizard — Interactive 5-Layer Backup Setup for Arch Linux  ║
# ║                                                                        ║
# ║  Usage:  sudo ./wizard.sh [--uninstall] [--verbose] [--help]           ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

WIZARD_VERSION="0.1.0"
WIZARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source library modules ────────────────────────────────────────────────────
source "$WIZARD_DIR/lib/common.sh"
source "$WIZARD_DIR/lib/ui.sh"
source "$WIZARD_DIR/lib/detect.sh"
source "$WIZARD_DIR/lib/packages.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

VERBOSE=false
UNINSTALL=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall)  UNINSTALL=true;  shift ;;
            --verbose|-v) VERBOSE=true;    shift ;;
            --help|-h)
                cat <<EOF
Arch Backup Wizard v${WIZARD_VERSION}

Sets up a production-grade 5-layer backup architecture for Arch Linux.

Usage:  sudo $0 [OPTIONS]

Options:
  --help, -h       Show this help message
  --verbose, -v    Enable verbose output to terminal
  --uninstall      Remove all wizard-created configurations

Layers:
  1  Snapper       Instant rollback via BTRFS snapshots
  2  btrbk         Daily OS clone to backup drive
  3  Pika Backup   Hourly home directory backups (Borg)
  4  Cloud Offsite Encrypted offsite via rclone
  5  Deep Storage  Local archive (not synced to cloud)

Requires:  BTRFS root filesystem, Arch-based distro (pacman)
EOF
                exit 0
                ;;
            *)
                echo "Unknown option: $1  (use --help)" >&2
                exit 1
                ;;
        esac
    done
}

# ── Welcome screen ────────────────────────────────────────────────────────────

show_welcome() {
    ui_msgbox "Arch Backup Wizard v${WIZARD_VERSION}" \
"Welcome to the Arch Backup Wizard!

This wizard will guide you through setting up a
production-grade 5-layer backup architecture:

  Layer 1  Snapper     Instant rollback on bad updates
  Layer 2  btrbk       Daily OS clone to backup drive
  Layer 3  Pika Backup Hourly home directory backups
  Layer 4  Cloud       Offsite backups to cloud storage
  Layer 5  Deep Storage Local archive (not synced)

Requirements:
  • Root filesystem must be BTRFS
  • A secondary drive for backup storage
  • Internet for cloud offsite (Layer 4)

Press OK to begin."
}

# ── Detection results ─────────────────────────────────────────────────────────

show_detection_results() {
    local summary
    summary=$(format_detection_summary)

    ui_yesno "System Detection" \
"Your system was scanned. Please verify:

$summary

Is this correct?" || die "Aborted by user at detection review."
}

# ── BTRFS gate ────────────────────────────────────────────────────────────────

check_btrfs() {
    if [[ "$DETECTED_ROOT_FS" != "btrfs" ]]; then
        ui_msgbox "BTRFS Required" \
"Your root filesystem is '$DETECTED_ROOT_FS'.

Layers 1 (Snapper) and 2 (btrbk) require BTRFS.
Most Arch-based installers (CachyOS, EndeavourOS,
Garuda) offer BTRFS during installation.

The wizard cannot continue."
        die "Root filesystem is not BTRFS ($DETECTED_ROOT_FS)."
    fi
}

# ── Layer selection ───────────────────────────────────────────────────────────

SELECTED_LAYERS=()
NEEDS_BACKUP_DRIVE=false

select_layers() {
    local result
    result=$(ui_checklist "Select Backup Layers" \
        "Choose which layers to set up (SPACE to toggle):" \
        "1" "Snapper — Instant rollback on bad updates"     "on" \
        "2" "btrbk — Daily OS clone to backup drive"        "on" \
        "3" "Pika Backup — Hourly home directory backups"   "on" \
        "4" "Cloud Offsite — Backups to cloud storage"      "on" \
        "5" "Deep Storage — Local archive (not synced)"     "on" \
    ) || die "Aborted by user at layer selection."

    SELECTED_LAYERS=()
    for tag in $result; do
        tag="${tag//\"/}"
        SELECTED_LAYERS+=("$tag")
    done

    [[ ${#SELECTED_LAYERS[@]} -eq 0 ]] && die "No layers selected."
    log_info "Selected layers: ${SELECTED_LAYERS[*]}"
}

# Check if a specific layer number was selected
layer_selected() {
    local target="$1"
    for l in "${SELECTED_LAYERS[@]}"; do
        [[ "$l" == "$target" ]] && return 0
    done
    return 1
}

# Enforce inter-layer dependencies
check_layer_deps() {
    NEEDS_BACKUP_DRIVE=false

    for l in 2 3 5; do
        layer_selected "$l" && NEEDS_BACKUP_DRIVE=true
    done

    if layer_selected "4"; then
        if ! layer_selected "2" && ! layer_selected "3"; then
            ui_msgbox "Dependency" \
"Layer 4 (Cloud Offsite) needs data to upload.

Please also select at least one of:
  • Layer 2 (btrbk OS clones)
  • Layer 3 (Pika home backups)"
            return 1
        fi
    fi
}

# ── Backup drive selection ────────────────────────────────────────────────────

BACKUP_MOUNT=""
BACKUP_UUID=""
BACKUP_DEV=""

select_backup_drive() {
    # If an existing backup mount was detected, offer to reuse it
    if [[ -n "$DETECTED_BACKUP_MOUNT" ]]; then
        if ui_yesno "Existing Backup Drive" \
"An existing backup mount was detected:

  Mount:  $DETECTED_BACKUP_MOUNT
  UUID:   $DETECTED_BACKUP_UUID
  Device: $DETECTED_BACKUP_DEV

Use this drive?"; then
            BACKUP_MOUNT="$DETECTED_BACKUP_MOUNT"
            BACKUP_UUID="$DETECTED_BACKUP_UUID"
            BACKUP_DEV="$DETECTED_BACKUP_DEV"
            log_info "Reusing existing backup drive: $BACKUP_MOUNT"
            return 0
        fi
    fi

    # Build a list of candidate partitions for a radiolist
    local choices=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local dev size _type fstype mountpoint
        read -r dev size _type fstype mountpoint <<< "$line"

        # Skip root and EFI
        [[ "$dev" == "$DETECTED_ROOT_DEV" ]] && continue
        [[ "$dev" == "$DETECTED_EFI_DEV" ]]  && continue
        [[ "$fstype" == "swap" ]]             && continue

        local label="${size}"
        [[ -n "$fstype" ]]     && label+="  $fstype"
        [[ -n "$mountpoint" ]] && label+="  ($mountpoint)"

        choices+=("$dev" "$label" "off")
    done <<< "$DETECTED_PARTITIONS"

    # Also offer unformatted whole disks
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local dev size _type
        read -r dev size _type <<< "$line"

        # Skip if any partition from this disk is already in the list
        local dominated=false
        for c in "${choices[@]}"; do
            [[ "$c" == "${dev}"* ]] && dominated=true && break
        done

        # Offer the whole disk as a "format new" option
        choices+=("$dev" "${size}  (UNFORMATTED — will partition)" "off")
    done <<< "$DETECTED_DRIVES"

    if [[ ${#choices[@]} -eq 0 ]]; then
        ui_msgbox "No Drives Found" \
"No candidate drives were found for backup storage.

Please connect a secondary drive and re-run the wizard."
        die "No backup drive candidates found."
    fi

    local selected
    selected=$(ui_radiolist "Backup Drive" \
        "Select the drive/partition for backups:" \
        "${choices[@]}") || die "Aborted at drive selection."

    selected="${selected//\"/}"
    BACKUP_DEV="$selected"

    # Determine if this needs formatting
    local fstype
    fstype=$(lsblk -no FSTYPE "$BACKUP_DEV" 2>/dev/null || echo "")

    if [[ -z "$fstype" ]] || [[ "$fstype" != "btrfs" ]]; then
        if ui_confirm_destructive "Format Drive" \
"The selected device ($BACKUP_DEV) is not BTRFS.

It needs to be formatted as BTRFS for backup storage.
THIS WILL ERASE ALL DATA ON $BACKUP_DEV.

Continue?"; then
            _format_backup_drive
        else
            die "Aborted: drive formatting declined."
        fi
    fi

    # Set up the mount point
    BACKUP_UUID=$(blkid -s UUID -o value "$BACKUP_DEV")

    if [[ -z "$BACKUP_MOUNT" ]]; then
        BACKUP_MOUNT=$(ui_inputbox "Mount Point" \
            "Where should the backup drive be mounted?" \
            "${DETECTED_HOME}/Backup") || die "Aborted at mount point input."
    fi

    _ensure_backup_mounted

    log_info "Backup drive configured: dev=$BACKUP_DEV mount=$BACKUP_MOUNT UUID=$BACKUP_UUID"
}

_format_backup_drive() {
    local dev="$BACKUP_DEV"

    # If it's a whole disk (not a partition), partition it first
    if [[ "$dev" =~ ^/dev/[a-z]+$ ]] || [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
        log_info "Partitioning whole disk: $dev"
        ui_infobox "Partitioning" "Creating GPT partition table on $dev..."

        parted -s "$dev" mklabel gpt >> "$LOG_FILE" 2>&1
        parted -s "$dev" mkpart primary btrfs 1MiB 100% >> "$LOG_FILE" 2>&1

        # Determine the new partition name
        if [[ "$dev" =~ nvme ]]; then
            BACKUP_DEV="${dev}p1"
        else
            BACKUP_DEV="${dev}1"
        fi
        sleep 1  # wait for udev
    fi

    log_info "Formatting $BACKUP_DEV as BTRFS with zstd compression"
    ui_infobox "Formatting" "Creating BTRFS filesystem on $BACKUP_DEV..."
    mkfs.btrfs -f "$BACKUP_DEV" >> "$LOG_FILE" 2>&1 || die "mkfs.btrfs failed on $BACKUP_DEV"
    log_success "Formatted $BACKUP_DEV as BTRFS"
}

_ensure_backup_mounted() {
    mkdir -p "$BACKUP_MOUNT"

    # Add to fstab if not already present
    if ! grep -q "$BACKUP_UUID" /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        printf '\nUUID=%s %s btrfs defaults,noatime,compress=zstd,nofail 0 0\n' \
            "$BACKUP_UUID" "$BACKUP_MOUNT" >> /etc/fstab
        log_info "Added backup drive to /etc/fstab"
    fi

    # Mount if not already mounted
    if ! mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
        mount "$BACKUP_MOUNT" >> "$LOG_FILE" 2>&1 || die "Failed to mount $BACKUP_MOUNT"
    fi

    # Create standard directory structure
    mkdir -p "$BACKUP_MOUNT/OS_Backup"
    mkdir -p "$BACKUP_MOUNT/Personal"
    mkdir -p "$BACKUP_MOUNT/Deep Storage"

    log_info "Backup mount ready at $BACKUP_MOUNT"
}

# ── Main flow ─────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    require_root

    # Set up log file under the real user's home
    LOG_FILE="$(get_real_home)/arch-backup-wizard.log"
    log_info "══════ Arch Backup Wizard v${WIZARD_VERSION} started ══════"

    # Ensure dialog is available before anything else
    ensure_dialog
    detect_dialog

    # Welcome
    show_welcome

    # Detect
    ui_infobox "Scanning" "Detecting your system configuration..."
    run_detection
    sleep 1

    # BTRFS gate
    check_btrfs

    # Show results
    show_detection_results

    # Layer selection (retry loop for dependency failures)
    while true; do
        select_layers
        check_layer_deps && break
    done

    # Backup drive (if any layer needs it)
    if $NEEDS_BACKUP_DRIVE; then
        select_backup_drive
    fi

    # ── Run layer setup modules ──────────────────────────────────────────
    source "$WIZARD_DIR/lib/layer1_snapper.sh"
    source "$WIZARD_DIR/lib/layer2_btrbk.sh"
    source "$WIZARD_DIR/lib/layer3_pika.sh"
    source "$WIZARD_DIR/lib/layer4_cloud.sh"
    source "$WIZARD_DIR/lib/layer5_deep_storage.sh"
    source "$WIZARD_DIR/lib/runbooks.sh"

    layer_selected "1" && setup_layer1
    layer_selected "2" && setup_layer2
    layer_selected "3" && setup_layer3
    layer_selected "4" && setup_layer4
    layer_selected "5" && setup_layer5

    # ── Runbook generation ────────────────────────────────────────────────
    generate_runbooks

    # ── Validation (Milestone 4) ──────────────────────────────────────────
    # source "$WIZARD_DIR/lib/validate.sh" && run_validation

    # ── Summary ───────────────────────────────────────────────────────────
    local layer_list="${SELECTED_LAYERS[*]}"
    local summary="Layers configured: $layer_list"
    [[ -n "${BACKUP_MOUNT:-}" ]] && summary+="\nBackup drive: $BACKUP_MOUNT"

    ui_msgbox "Setup Complete" \
"The following layers have been configured:

  $summary

Recovery runbooks saved to: ${BACKUP_MOUNT:-N/A}

Remaining (Milestone 4):
  • Post-setup validation checks

Log file: $LOG_FILE"

    log_info "══════ Wizard completed ══════"
}

main "$@"
