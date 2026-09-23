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
    cachyos) DETECTED_DISTRO="CachyOS" ;;
    endeavouros) DETECTED_DISTRO="EndeavourOS" ;;
    manjaro) DETECTED_DISTRO="Manjaro" ;;
    garuda) DETECTED_DISTRO="Garuda" ;;
    arch) DETECTED_DISTRO="Arch" ;;
    *) DETECTED_DISTRO="$DETECTED_DISTRO_NAME" ;;
    esac

    log_info "Detected distro: $DETECTED_DISTRO ($DETECTED_DISTRO_ID)"
}

# ── AUR helper ────────────────────────────────────────────────────────────────

detect_aur_helper() {
    DETECTED_AUR_HELPER=""
    for helper in paru yay; do
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

    if [[ -f /etc/default/limine ]] || cmd_exists limine; then
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
    DETECTED_ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
    DETECTED_ROOT_DEV=$(findmnt -n --nofsroot -o SOURCE / 2>/dev/null || echo "")
    DETECTED_ROOT_UUID=$(findmnt -n -o UUID / 2>/dev/null || echo "")
    DETECTED_ROOT_SUBVOL=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -oP 'subvol=\K[^,]+' || echo "")

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
                DETECTED_EFI_DEV=$(findmnt -n --nofsroot -o SOURCE "$mount")
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
    DETECTED_SUBVOL_MOUNTS=()
    DETECTED_SECONDARY_MOUNTS=()

    if [[ "$DETECTED_ROOT_FS" == "btrfs" ]]; then
        local subvol_list=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ $line =~ TARGET=\"([^\"]*)\".*UUID=\"([^\"]*)\".*OPTIONS=\"([^\"]*)\" ]] || continue
            local target="${BASH_REMATCH[1]}"
            local uuid="${BASH_REMATCH[2]}"
            local opts="${BASH_REMATCH[3]}"

            if [[ "$uuid" == "$DETECTED_ROOT_UUID" ]]; then
                if [[ "$opts" =~ subvol=([^,]+) ]]; then
                    local subvol="${BASH_REMATCH[1]}"
                    subvol="${subvol#/}"
                    [[ -z "$subvol" ]] && subvol="@"

                    if [[ "$subvol" != *".snapshots"* ]]; then
                        subvol_list+=("$subvol")
                        DETECTED_SUBVOL_MOUNTS+=("$target:$subvol")
                    fi
                fi
            else
                # This is a different filesystem or different BTRFS UUID
                if [[ "$target" != "/boot" && "$target" != "/boot/efi" && "$target" != "/efi" && "$target" != "/mnt"* && "$target" != "/run"* ]]; then
                    DETECTED_SECONDARY_MOUNTS+=("$target")
                fi
            fi
        done < <(findmnt -n -P -o TARGET,UUID,OPTIONS -t btrfs,ext4,xfs,f2fs,vfat,exfat,ntfs 2>/dev/null)

        if (( ${#subvol_list[@]} > 0 )); then
            mapfile -t subvol_list < <(printf "%s\n" "${subvol_list[@]}" | sort -u)
            DETECTED_SUBVOLUMES=$(printf "%s\n" "${subvol_list[@]}")
            DETECTED_SUBVOL_LAYOUT=$(paste -sd',' <<<"$DETECTED_SUBVOLUMES" | sed 's/,/, /g')
        fi
        log_info "BTRFS layout: $DETECTED_SUBVOL_LAYOUT"

        # Check for unmounted nested subvolumes (Audit-036)
        DETECTED_UNMOUNTED_SUBVOLS=""
        local all_subvols
        all_subvols=$(btrfs subvolume list -o / 2>/dev/null | sed -n 's/.* path //p' | grep -v '\.snapshots' || true)
        local unmounted_subvols=()
        for s in $all_subvols; do
            local found=false
            for m in "${subvol_list[@]}"; do
                if [[ "$s" == "$m" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                unmounted_subvols+=("$s")
            fi
        done
        if (( ${#unmounted_subvols[@]} > 0 )); then
            DETECTED_UNMOUNTED_SUBVOLS=$(printf "%s\n" "${unmounted_subvols[@]}")
            log_warn "Detected unmounted nested subvolumes that will not be backed up."
        fi
    fi
}

# ── System devices (for exclusion) ────────────────────────────────────────────

detect_system_devices() {
    DETECTED_SYSTEM_DEVS=()
    local critical_mounts=()
    mapfile -t critical_mounts < <(lsblk -rno MOUNTPOINT 2>/dev/null | grep -v '^$' | grep -v '\[SWAP\]' | grep -vE '^(/run/media|/mnt)' || true)

    # Ensure standard mounts are checked even if unmounted currently (if they somehow exist)
    critical_mounts+=(/ /boot /boot/efi /efi)

    for mnt in "${critical_mounts[@]}"; do
        local fstype
        fstype=$(findmnt -n -o FSTYPE "$mnt" 2>/dev/null || true)

        local devs=()
        if [[ "$fstype" == "btrfs" ]]; then
            # Handle multi-device BTRFS roots
            mapfile -t devs < <(btrfs filesystem show "$mnt" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="path") print $(i+1)}' || true)
        else
            local dev
            dev=$(findmnt -n --nofsroot -o SOURCE "$mnt" 2>/dev/null || true)
            [[ -n "$dev" ]] && devs+=("$dev")
        fi

        for d in "${devs[@]}"; do
            local tree
            tree=$(lsblk -s -nlo KNAME "$d" 2>/dev/null || true)
            for k in $tree; do
                DETECTED_SYSTEM_DEVS+=("/dev/$k")
            done
        done
    done

    local swaps
    swaps=$(swapon --show=NAME --noheadings 2>/dev/null || true)
    for swp in $swaps; do
        local tree
        tree=$(lsblk -s -nlo KNAME "$swp" 2>/dev/null || true)
        for k in $tree; do
            DETECTED_SYSTEM_DEVS+=("/dev/$k")
        done
    done

    # Remove duplicates
    if (( ${#DETECTED_SYSTEM_DEVS[@]} > 0 )); then
        mapfile -t DETECTED_SYSTEM_DEVS < <(printf "%s\n" "${DETECTED_SYSTEM_DEVS[@]}" | sort -u)
    fi
}

# ── Available drives (for backup target selection) ────────────────────────────

detect_available_drives() {
    # Whole disks (for potential formatting)
    DETECTED_DRIVES=$(lsblk -P -dpno NAME,SIZE,TYPE,FSTYPE 2>/dev/null |
        grep 'TYPE="disk"' |
        grep -vE 'loop|rom|sr0' || echo "")

    # Partitions with filesystem info
    DETECTED_PARTITIONS=$(lsblk -P -pno NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null |
        grep -E 'TYPE="(part|crypt|lvm)"' |
        grep -vE 'loop|rom' || echo "")

    log_info "Drive scan complete"
}

# ── Existing backup drive ─────────────────────────────────────────────────────

detect_existing_backup_drive() {
    DETECTED_BACKUP_MOUNT=""
    DETECTED_BACKUP_UUID=""
    DETECTED_BACKUP_DEV=""

    # Parse fstab explicitly with findmnt
    local fstab_entries
    fstab_entries=$(findmnt --fstab -P -o TARGET,UUID,FSTYPE 2>/dev/null || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ $line =~ TARGET=\"([^\"]*)\".*UUID=\"([^\"]*)\".*FSTYPE=\"([^\"]*)\" ]] || true
        local target="${BASH_REMATCH[1]:-}"
        local uuid="${BASH_REMATCH[2]:-}"
        local fstype="${BASH_REMATCH[3]:-}"

        local is_managed_fstab=false
        if awk -v t1="$target" -v t2="${target// /\\040}" '
            /# BEGIN Arch Backup Wizard/{f=1; next}
            /# END Arch Backup Wizard/{f=0}
            f && ($2 == t1 || $2 == t2) {found=1}
            END{exit !found}
        ' /etc/fstab 2>/dev/null; then
            is_managed_fstab=true
        elif grep -qE "^[^#]*[[:space:]]+${target}[[:space:]].*#.*Arch Backup Wizard" /etc/fstab 2>/dev/null; then
            is_managed_fstab=true
        fi

        if [[ -d "$target/OS_Backup" ]] || $is_managed_fstab; then
            # Must be a BTRFS filesystem
            [[ "$fstype" != "btrfs" ]] && continue

            # Check if it is on the root filesystem (ignore if it's the same device)
            local target_dev
            target_dev=$(findmnt -n --nofsroot -o SOURCE "$target" 2>/dev/null || echo "")

            # Allow fallback if the drive isn't currently mounted but has a UUID
            if [[ -z "$target_dev" && -n "$uuid" ]]; then
                target_dev=$(blkid -U "$uuid" 2>/dev/null || echo "")
            fi

            local is_system=false
            if [[ -n "$target_dev" ]]; then
                for sys_dev in "${DETECTED_SYSTEM_DEVS[@]}"; do
                    if [[ "$target_dev" == "$sys_dev" ]]; then
                        is_system=true
                        break
                    fi
                done
            fi

            if [[ "$is_system" == false && -n "$target_dev" ]]; then
                DETECTED_BACKUP_MOUNT="$target"
                DETECTED_BACKUP_UUID="$uuid"
                DETECTED_BACKUP_DEV="$target_dev"
                break
            fi
        fi
    done <<<"$fstab_entries"

    log_info "Backup drive: mount=$DETECTED_BACKUP_MOUNT UUID=$DETECTED_BACKUP_UUID"
}

# ── User info ─────────────────────────────────────────────────────────────────

detect_user_info() {
    DETECTED_USER=$(get_real_user)
    DETECTED_HOME=$(getent passwd "$DETECTED_USER" | cut -d: -f6)
    DETECTED_SHELL=$(getent passwd "$DETECTED_USER" | cut -d: -f7)
    DETECTED_HOSTNAME=$(cat /etc/hostname 2>/dev/null || uname -n || echo "localhost")

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

    # Config file existence
    DETECTED_SNAPPER_CONFIG_EXISTS=false
    [[ -f /etc/snapper/configs/root ]] && DETECTED_SNAPPER_CONFIG_EXISTS=true

    log_info "Existing tools: snapper-config=$DETECTED_SNAPPER_CONFIG_EXISTS"
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
    detect_system_devices
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
