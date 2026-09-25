#!/bin/bash
set -euxo pipefail

# Output to console directly so host can see progress
exec > >(tee -a /dev/ttyS0 /var/log/btrfs-migration.log) 2>&1

echo "============================================================"
echo "      AUTOMATED ARCH LINUX BTRFS VM SETUP STARTING"
echo "============================================================"

if blkid /dev/vdb2 2>/dev/null | grep -q btrfs; then
    echo "=== Detected existing BTRFS setup on /dev/vdb2 — updating wizard code and tests ==="
    mkdir -p /mnt/target-update
    mount -o subvol=@root /dev/vdb2 /mnt/target-update
    rm -rf /mnt/target-update/arch-backup-wizard
    mkdir -p /mnt/target-update/arch-backup-wizard
    if [[ -d /mnt/cidata/wizard-code ]]; then
        cp -r /mnt/cidata/wizard-code/. /mnt/target-update/arch-backup-wizard/
    elif [[ -d /mnt/cidata/lib ]]; then
        cp -r /mnt/cidata/lib /mnt/cidata/templates /mnt/cidata/tests /mnt/cidata/wizard.sh /mnt/cidata/Makefile /mnt/cidata/README.md /mnt/target-update/arch-backup-wizard/
        [[ -f /mnt/cidata/.shellcheckrc ]] && cp /mnt/cidata/.shellcheckrc /mnt/target-update/arch-backup-wizard/
    fi
    [[ -f /mnt/cidata/.shellcheckrc ]] && cp /mnt/cidata/.shellcheckrc /mnt/target-update/arch-backup-wizard/
    cp /mnt/cidata/run_vm_tests.sh /mnt/target-update/arch-backup-wizard/
    chmod +x /mnt/target-update/arch-backup-wizard/wizard.sh /mnt/target-update/arch-backup-wizard/run_vm_tests.sh
    sync
    umount /mnt/target-update
    echo "=== WIZARD CODE UPDATED! POWERING OFF ==="
    poweroff
    exit 0
fi

echo "=== [1/7] Partitioning /dev/vdb ==="
pacman -Sy --noconfirm parted
parted -s /dev/vdb mklabel gpt
parted -s /dev/vdb mkpart esp fat32 1MiB 513MiB
parted -s /dev/vdb set 1 esp on
parted -s /dev/vdb mkpart root btrfs 513MiB 100%

sleep 2
udevadm settle || true

mkfs.fat -F 32 /dev/vdb1
mkfs.btrfs -f /dev/vdb2

echo "=== [2/7] Creating BTRFS subvolumes on /dev/vdb2 ==="
mkdir -p /mnt/btrfs-raw
mount /dev/vdb2 /mnt/btrfs-raw
btrfs subvolume create /mnt/btrfs-raw/@
btrfs subvolume create /mnt/btrfs-raw/@home
btrfs subvolume create /mnt/btrfs-raw/@log
btrfs subvolume create /mnt/btrfs-raw/@cache
btrfs subvolume create /mnt/btrfs-raw/@tmp
btrfs subvolume create /mnt/btrfs-raw/@srv
btrfs subvolume create /mnt/btrfs-raw/@root
btrfs subvolume create /mnt/btrfs-raw/@/.snapshots

DEFAULT_ID=$(btrfs subvolume list /mnt/btrfs-raw | awk '/ path @$/{print $2}')
btrfs subvolume set-default "$DEFAULT_ID" /mnt/btrfs-raw
umount /mnt/btrfs-raw

echo "=== [3/7] Mounting BTRFS subvolumes at /mnt/target ==="
mkdir -p /mnt/target
mount -o subvol=@ /dev/vdb2 /mnt/target
mkdir -p /mnt/target/{boot,home,var/log,var/cache,var/tmp,srv,root}
mount /dev/vdb1 /mnt/target/boot
mount -o subvol=@home /dev/vdb2 /mnt/target/home
mount -o subvol=@log /dev/vdb2 /mnt/target/var/log
mount -o subvol=@cache /dev/vdb2 /mnt/target/var/cache
mount -o subvol=@tmp /dev/vdb2 /mnt/target/var/tmp
mount -o subvol=@srv /dev/vdb2 /mnt/target/srv
mount -o subvol=@root /dev/vdb2 /mnt/target/root

echo "=== [4/7] Copying OS files to BTRFS target ==="
cp -ax / /mnt/target/
cp -ax /home/. /mnt/target/home/
mkdir -p /mnt/target/{proc,sys,dev,run,tmp}

# Copy wizard code into target
if [[ -d /mnt/cidata/wizard-code ]]; then
    mkdir -p /mnt/target/root/arch-backup-wizard
    cp -r /mnt/cidata/wizard-code/. /mnt/target/root/arch-backup-wizard/
    chmod +x /mnt/target/root/arch-backup-wizard/wizard.sh
fi
if [[ -f /mnt/cidata/run_vm_tests.sh ]]; then
    cp /mnt/cidata/run_vm_tests.sh /mnt/target/root/arch-backup-wizard/
    chmod +x /mnt/target/root/arch-backup-wizard/run_vm_tests.sh
fi

echo "=== [5/7] Updating fstab and system config on target ==="
BTRFS_UUID=$(blkid -s UUID -o value /dev/vdb2)
EFI_UUID=$(blkid -s UUID -o value /dev/vdb1)

cat <<FSTAB > /mnt/target/etc/fstab
UUID=${EFI_UUID}  /boot      vfat   defaults,umask=0077 0 2
UUID=${BTRFS_UUID} /          btrfs  subvol=/@,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /home      btrfs  subvol=/@home,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /root      btrfs  subvol=/@root,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /srv       btrfs  subvol=/@srv,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /var/cache btrfs  subvol=/@cache,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /var/tmp   btrfs  subvol=/@tmp,defaults,noatime,compress=zstd:1 0 0
UUID=${BTRFS_UUID} /var/log   btrfs  subvol=/@log,defaults,noatime,compress=zstd:1 0 0
tmpfs             /tmp       tmpfs  defaults,noatime,mode=1777 0 0
FSTAB

# Passwords
echo "root:arch" | chroot /mnt/target chpasswd
echo "arch:arch" | chroot /mnt/target chpasswd

# Auto-login on ttyS0 for testing
mkdir -p /mnt/target/etc/systemd/system/serial-getty@ttyS0.service.d/
cat <<AUTOLOGIN > /mnt/target/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root -s %I 115200,38400,9600 vt220
AUTOLOGIN

echo "=== [6/7] Installing GRUB EFI bootloader ==="
mount --bind /dev /mnt/target/dev
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
mount --bind /run /mnt/target/run

chroot /mnt/target pacman-key --init || true
chroot /mnt/target pacman-key --populate archlinux || true
chroot /mnt/target pacman -Sy --noconfirm grub efibootmgr dialog snapper btrfs-progs btrbk borg rclone age zstd shellcheck make pv zenity
chroot /mnt/target grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&console=ttyS0 /' /mnt/target/etc/default/grub
sed -i 's/^#*GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="serial"/' /mnt/target/etc/default/grub
sed -i 's/^#*GRUB_TERMINAL_INPUT=.*/GRUB_TERMINAL_INPUT="serial"/' /mnt/target/etc/default/grub
echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> /mnt/target/etc/default/grub
chroot /mnt/target grub-mkconfig -o /boot/grub/grub.cfg

# Setup automated VM test service
cat <<UNIT > /mnt/target/etc/systemd/system/run-vm-tests.service
[Unit]
Description=Run Arch Backup Wizard VM Tests
After=multi-user.target
ConditionPathExists=/root/arch-backup-wizard/run_vm_tests.sh

[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/bash /root/arch-backup-wizard/run_vm_tests.sh
ExecStopPost=/usr/bin/poweroff

[Install]
WantedBy=multi-user.target
UNIT
chroot /mnt/target systemctl enable run-vm-tests.service

echo "=== [7/7] BTRFS MIGRATION FINISHED! POWERING OFF ==="
touch /mnt/target/BTRFS_MIGRATION_SUCCESS
sync
poweroff
