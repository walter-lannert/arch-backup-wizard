#!/usr/bin/env bash
# arch-backup-wizard/lib/detect.sh — System detection engine
#
# All detected values are stored as global variables prefixed with DETECTED_.
# Call run_detection() to populate everything at once.

# ── Distro ────────────────────────────────────────────────────────────────────

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DETECTED_DISTRO_ID="${ID:-unknown}"
        DETECTED_DISTRO_NAME="${NAME:-Unknown}"
        DETECTED_DISTRO_PRETTY="${PRETTY_NAME:-Unknown Linux}"
    else
        DETECTED_DISTRO_ID="unknown"
        DETECTED_DISTRO_NAME="Unknown"
        DETECTED_DISTRO_PRETTY="Unknown Linux"
    fi

    case "$DETECTED_DISTRO_ID" in
        cachyos)       DETECTED_DISTRO="CachyOS"      ;;
        endeavouros)   DETECTED_DISTRO="EndeavourOS"   ;;
        manjaro)       DETECTED_DISTRO="Manjaro"       ;;
        garuda)        DETECTED_DISTRO="Garuda"        ;;
        arch)          DETECTED_DISTRO="Arch"          ;;
        *)             DETECTED_DISTRO="$DETECTED_DISTRO_NAME" ;;
    esac

    log_info "Detected distro: $DETECTED_DISTRO ($DETECTED_DISTRO_ID)"
}

# ── AUR helper ────────────────────────────────────────────────────────────────

detect_aur_helper() {
    DETECTED_AUR_HELPER=""
    for helper in paru yay pamac; do
        if cmd_exists "$helper"; then
            DETECTED_AUR_HELPER="$helper"
            break
        fi
    done
    log_info "AUR helper: ${DETECTED_AUR_HELPER:-none}"
}

# ── Bootloader ────────────────────────────────────────────────────────────────

detect_bootloader() {
    DETECTED_BOOTLOADER="unknown"

    if [[ -f /etc/default/limine ]] || cmd_exists limine-mkinitcpio; then
        DETECTED_BOOTLOADER="limine"
    elif [[ -f /etc/default/grub ]] || [[ -d /boot/grub ]]; then
        DETECTED_BOOTLOADER="grub"
    elif [[ -d /boot/loader/entries ]] || bootctl is-installed &>/dev/null 2>&1; then
        DETECTED_BOOTLOADER="systemd-boot"
    fi

    log_info "Bootloader: $DETECTED_BOOTLOADER"
}

# ── Root filesystem ───────────────────────────────────────────────────────────

detect_root_filesystem() {
    DETECTED_ROOT_FS=$(findmnt -n -o FSTYPE /)
    DETECTED_ROOT_DEV=$(findmnt -n -o SOURCE /)
    DETECTED_ROOT_UUID=$(findmnt -n -o UUID /)
    DETECTED_ROOT_SUBVOL=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+' || echo "")

    log_info "Root: $DETECTED_ROOT_FS dev=$DETECTED_ROOT_DEV UUID=$DETECTED_ROOT_UUID subvol=$DETECTED_ROOT_SUBVOL"
}

# ── EFI partition ─────────────────────────────────────────────────────────────

detect_efi() {
    DETECTED_EFI_DEV=""
    DETECTED_EFI_UUID=""
    DETECTED_EFI_MOUNT=""

    local mount
    for mount in /boot /boot/efi /efi; do
        if findmnt -n "$mount" &>/dev/null; then
            local fstype
            fstype=$(findmnt -n -o FSTYPE "$mount")
            if [[ "$fstype" == "vfat" ]]; then
                DETECTED_EFI_MOUNT="$mount"
                DETECTED_EFI_DEV=$(findmnt -n -o SOURCE "$mount")
                DETECTED_EFI_UUID=$(findmnt -n -o UUID "$mount")
                break
            fi
        fi
    done

    log_info "EFI: dev=$DETECTED_EFI_DEV mount=$DETECTED_EFI_MOUNT UUID=$DETECTED_EFI_UUID"
}

# ── BTRFS subvolume layout ────────────────────────────────────────────────────

detect_btrfs_subvolumes() {
    DETECTED_SUBVOLUMES=""
    DETECTED_SUBVOL_LAYOUT=""

    if [[ "$DETECTED_ROOT_FS" == "btrfs" ]]; then
        # List top-level subvolumes (those whose path starts with @)
        DETECTED_SUBVOLUMES=$(btrfs subvolume list / 2>/dev/null \
            | awk '{print $NF}' \
            | grep '^@' \
            | grep -v '\.snapshots' \
            | sort || echo "")
        DETECTED_SUBVOL_LAYOUT=$(echo "$DETECTED_SUBVOLUMES" | paste -sd',' - | sed 's/,/, /g')
        log_info "BTRFS layout: $DETECTED_SUBVOL_LAYOUT"
    fi
}

# ── Available drives (for backup target selection) ────────────────────────────

detect_available_drives() {
    # Whole disks (for potential formatting)
    DETECTED_DRIVES=$(lsblk -dpno NAME,SIZE,TYPE 2>/dev/null \
        | grep -E 'disk' \
        | grep -v 'loop\|rom\|sr0' || echo "")

    # Partitions with filesystem info
    DETECTED_PARTITIONS=$(lsblk -pno NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null \
        | grep 'part' \
        | grep -v 'loop\|rom' || echo "")

    log_info "Drive scan complete"
}

# ── Existing backup drive ─────────────────────────────────────────────────────

detect_existing_backup_drive() {
    DETECTED_BACKUP_MOUNT=""
    DETECTED_BACKUP_UUID=""
    DETECTED_BACKUP_DEV=""

    # Scan fstab for anything mounted at a path containing "backup" (case-insensitive)
    while IFS= read -r line; do
        local mnt
        mnt=$(echo "$line" | awk '{print $2}')
        if echo "$mnt" | grep -qi 'backup'; then
            DETECTED_BACKUP_MOUNT="$mnt"
            DETECTED_BACKUP_UUID=$(echo "$line" | grep -oP 'UUID=\K\S+' || echo "")
            DETECTED_BACKUP_DEV=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || echo "")
            break
        fi
    done < <(grep -v '^\s*#' /etc/fstab | grep -v '^\s*$')

    log_info "Backup drive: mount=$DETECTED_BACKUP_MOUNT UUID=$DETECTED_BACKUP_UUID"
}

# ── User info ─────────────────────────────────────────────────────────────────

detect_user_info() {
    DETECTED_USER=$(get_real_user)
    DETECTED_HOME=$(get_real_home)
    DETECTED_SHELL=$(getent passwd "$DETECTED_USER" | cut -d: -f7)
    DETECTED_HOSTNAME=$(hostname)
    DETECTED_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")

    log_info "User=$DETECTED_USER Home=$DETECTED_HOME Shell=$DETECTED_SHELL Host=$DETECTED_HOSTNAME"
}

# ── Default terminal emulator (for nag script) ───────────────────────────────

detect_terminal() {
    DETECTED_TERMINAL_CMD=""

    local -a candidates=(
        "ptyxis --"
        "kgx -e"
        "konsole -e"
        "xfce4-terminal -e"
        "gnome-terminal --"
        "alacritty -e"
        "kitty"
        "xterm -e"
    )

    for entry in "${candidates[@]}"; do
        local bin="${entry%% *}"
        if cmd_exists "$bin"; then
            DETECTED_TERMINAL_CMD="$entry"
            break
        fi
    done

    log_info "Terminal: ${DETECTED_TERMINAL_CMD:-none}"
}

# ── Existing tool installations ───────────────────────────────────────────────

detect_existing_setup() {
    DETECTED_HAS_SNAPPER=false
    DETECTED_HAS_BTRBK=false
    DETECTED_HAS_PIKA=false
    DETECTED_HAS_RCLONE=false
    DETECTED_HAS_SNAP_PAC=false

    pacman -Qi snapper   &>/dev/null && DETECTED_HAS_SNAPPER=true
    pacman -Qi btrbk     &>/dev/null && DETECTED_HAS_BTRBK=true
    pacman -Qi pika-backup &>/dev/null && DETECTED_HAS_PIKA=true
    pacman -Qi rclone    &>/dev/null && DETECTED_HAS_RCLONE=true
    pacman -Qi snap-pac  &>/dev/null && DETECTED_HAS_SNAP_PAC=true

    # Config file existence
    DETECTED_SNAPPER_CONFIG_EXISTS=false
    [[ -f /etc/snapper/configs/root ]] && DETECTED_SNAPPER_CONFIG_EXISTS=true

    DETECTED_BTRBK_CONFIG_EXISTS=false
    [[ -f /etc/btrbk/btrbk.conf ]] && DETECTED_BTRBK_CONFIG_EXISTS=true

    DETECTED_PIKA_CONFIG_EXISTS=false
    [[ -f "$(get_real_home)/.config/pika-backup/backup.json" ]] && DETECTED_PIKA_CONFIG_EXISTS=true

    DETECTED_RCLONE_CONFIG_EXISTS=false
    [[ -f "$(get_real_home)/.config/rclone/rclone.conf" ]] && DETECTED_RCLONE_CONFIG_EXISTS=true

    log_info "Existing tools: snapper=$DETECTED_HAS_SNAPPER btrbk=$DETECTED_HAS_BTRBK pika=$DETECTED_HAS_PIKA rclone=$DETECTED_HAS_RCLONE snap-pac=$DETECTED_HAS_SNAP_PAC"
}

# ── Master detection ──────────────────────────────────────────────────────────

run_detection() {
    log_info "── Starting system detection ──"
    detect_distro
    detect_aur_helper
    detect_bootloader
    detect_root_filesystem
    detect_efi
    detect_btrfs_subvolumes
    detect_available_drives
    detect_existing_backup_drive
    detect_user_info
    detect_terminal
    detect_existing_setup
    log_info "── System detection complete ──"
}

# Pretty-print detection results (for display in a dialog)
format_detection_summary() {
    cat <<EOF
Distro:          $DETECTED_DISTRO ($DETECTED_DISTRO_PRETTY)
Bootloader:      $DETECTED_BOOTLOADER
Root Filesystem: $DETECTED_ROOT_FS (UUID: ${DETECTED_ROOT_UUID:0:13}…)
Root Subvolume:  ${DETECTED_ROOT_SUBVOL:-N/A}
EFI Partition:   ${DETECTED_EFI_DEV:-Not found} (UUID: ${DETECTED_EFI_UUID:-N/A})
BTRFS Layout:    ${DETECTED_SUBVOL_LAYOUT:-N/A}
AUR Helper:      ${DETECTED_AUR_HELPER:-Not found}
User:            $DETECTED_USER ($DETECTED_HOME)
Shell:           $DETECTED_SHELL
Hostname:        $DETECTED_HOSTNAME
Backup Drive:    ${DETECTED_BACKUP_MOUNT:-Not configured}
EOF
}

# Build dialog-formatted list of candidate backup partitions
# Output: tag1 label1 tag2 label2 …  (suitable for ui_radiolist)
format_backup_drive_choices() {
    local root_dev="$DETECTED_ROOT_DEV"
    local efi_dev="$DETECTED_EFI_DEV"

    while IFS= read -r line; do
        local dev size _type fstype mountpoint
        read -r dev size _type fstype mountpoint <<< "$line"

        # Skip root and EFI partitions
        [[ "$dev" == "$root_dev" ]] && continue
        [[ "$dev" == "$efi_dev"  ]] && continue
        # Skip tiny partitions (< 10G typically EFI or swap)
        # Skip swap
        [[ "$fstype" == "swap" ]] && continue

        local label="${size}"
        [[ -n "$fstype" ]]     && label+="  $fstype"
        [[ -n "$mountpoint" ]] && label+="  ($mountpoint)"

        echo "$dev"
        echo "$label"
    done <<< "$DETECTED_PARTITIONS"
}
