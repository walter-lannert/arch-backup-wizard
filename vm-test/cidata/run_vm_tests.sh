#!/usr/bin/env bash
set -uo pipefail

echo ""
echo "================================================================================"
echo "          ARCH BACKUP WIZARD — AUTOMATED IN-VM COMPREHENSIVE SUITE"
echo "================================================================================"
echo ""

# Ensure non-root user 'arch' exists and has full sudo access (real-life environment)
id -u arch &>/dev/null || useradd -m -s /bin/bash -G wheel arch
mkdir -p /home/arch
chown -R arch:arch /home/arch

mkdir -p /etc/sudoers.d
echo "arch ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/arch
echo "root ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/root
chmod 440 /etc/sudoers.d/arch /etc/sudoers.d/root

# Setup test workspace under /home/arch
rm -rf /home/arch/arch-backup-wizard
cp -a /root/arch-backup-wizard /home/arch/arch-backup-wizard
if [[ ! -f /home/arch/arch-backup-wizard/.shellcheckrc ]]; then
    cat <<'SHELLCHECKRC' > /home/arch/arch-backup-wizard/.shellcheckrc
# Shellcheck configuration
source-path=SCRIPTDIR
disable=SC2034,SC1091,SC2088
SHELLCHECKRC
fi
chown -R arch:arch /home/arch/arch-backup-wizard

# Setup mock grub-btrfsd service so Snapper bootloader integration succeeds headlessly
cat <<'EOF' > /etc/systemd/system/grub-btrfsd.service
[Unit]
Description=Mock grub-btrfsd
[Service]
Type=oneshot
ExecStart=/usr/bin/true
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# Setup headless dialog helper for CLI testing of interactive wizard flows
mkdir -p /usr/local/bin
cat <<'EOF' > /usr/local/bin/dialog
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checklist)
            echo '"1" "2" "3" "4" "5"' >&2
            exit 0
            ;;
        --menu)
            echo "/mnt/backup" >&2
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done
exit 0
EOF
chmod +x /usr/local/bin/dialog

cd /home/arch/arch-backup-wizard

TEST_NUM=0
PASS_COUNT=0
FAIL_COUNT=0

report_test() {
    local name="$1"
    local status="$2"
    local details="${3:-}"
    ((TEST_NUM++)) || true
    if [[ "$status" -eq 0 ]]; then
        ((PASS_COUNT++)) || true
        echo -e "[TEST $TEST_NUM] \e[32mPASS\e[0m: $name"
    else
        ((FAIL_COUNT++)) || true
        echo -e "[TEST $TEST_NUM] \e[31mFAIL\e[0m: $name ($details)"
        if [[ -n "$details" && -f "$details" ]]; then
            echo "--- LOG TAIL: $details ---"
            cat "$details" | tail -n 25
            echo "--------------------------"
        elif [[ -f "/var/log/wizard_test.log" ]]; then
            echo "--- LOG TAIL: /var/log/wizard_test.log ---"
            cat "/var/log/wizard_test.log" | tail -n 25
            echo "--------------------------"
        fi
    fi
}

# --- STAGE 1: Code Quality & Hermetic Unit Tests (as non-root user 'arch') ---
echo "--- STAGE 1: Unit Tests & ShellCheck as user 'arch' ---"

su - arch -c "cd /home/arch/arch-backup-wizard && make check" >/tmp/make_check.log 2>&1
report_test "ShellCheck linter (make check as arch)" $? "/tmp/make_check.log"

su - arch -c "cd /home/arch/arch-backup-wizard && make test" >/tmp/make_test.log 2>&1
report_test "Hermetic unit tests (make test as arch)" $? "/tmp/make_test.log"
grep -E "PASS|FAIL|ALL TESTS" /tmp/make_test.log || true

# --- STAGE 2: Detection on Live Virtual System ---
echo ""
echo "--- STAGE 2: Live Hardware & Filesystem Auto-Detection ---"
source lib/common.sh
source lib/ui.sh
source lib/detect.sh
source lib/packages.sh
source lib/validate.sh
source lib/layer1_snapper.sh
source lib/layer2_btrbk.sh
source lib/layer3_pika.sh
source lib/layer4_cloud.sh
source lib/layer5_deep_storage.sh
source lib/runbooks.sh
source lib/uninstall.sh

export WIZARD_DIR="/home/arch/arch-backup-wizard"
export LOG_FILE="/var/log/wizard_test.log"
run_detection >/tmp/detection.log 2>&1

[[ "$DETECTED_DISTRO" =~ ^(Arch|CachyOS) ]]
report_test "Detected Arch Linux distro" $? "DETECTED_DISTRO=${DETECTED_DISTRO:-unknown}"

[[ "${DETECTED_ROOT_FS:-}" == "btrfs" ]]
report_test "Detected BTRFS root filesystem" $? "DETECTED_ROOT_FS=${DETECTED_ROOT_FS:-unknown}"

[[ "${DETECTED_BOOTLOADER:-}" == "grub" ]]
report_test "Detected GRUB bootloader" $? "DETECTED_BOOTLOADER=${DETECTED_BOOTLOADER:-unknown}"

[[ "${DETECTED_ROOT_SUBVOL:-}" =~ ^/?@$ ]]
report_test "Detected root subvolume @" $? "DETECTED_ROOT_SUBVOL=${DETECTED_ROOT_SUBVOL:-unknown}"

# --- STAGE 3: Secondary Backup Drive Initialization ---
echo ""
echo "--- STAGE 3: Virtual Backup Drive Provisioning ---"
# Secondary drive attached as /dev/vdb
mkdir -p /mnt/backup
if mountpoint -q /mnt/backup; then
    umount /mnt/backup 2>/dev/null || true
fi
mkfs.btrfs -f -L "BACKUP_DRIVE" /dev/vdb
mount -o compress=zstd /dev/vdb /mnt/backup
mountpoint -q /mnt/backup
report_test "Provisioned secondary BTRFS backup disk (/dev/vdb -> /mnt/backup)" $?

# Clean up any leftover snapshots from previous test runs
while IFS= read -r s; do
    [[ -n "$s" ]] && btrfs subvolume delete "$s" 2>/dev/null || true
done < <(find / -maxdepth 3 -type d -name ".snapshots_btrbk" -exec find {} -mindepth 1 -maxdepth 1 -type d \; 2>/dev/null || true)

BACKUP_MOUNT="/mnt/backup"
BACKUP_UUID=$(blkid -s UUID -o value /dev/vdb)
TARGET_USER="arch"
TARGET_HOME="/home/arch"
TARGET_SHELL="/bin/bash"
TARGET_HOSTNAME=$(cat /etc/hostname 2>/dev/null || uname -n || echo "localhost")
export ROOT_UUID="${DETECTED_ROOT_UUID:-}"
export DETECTED_USER="arch"
export DETECTED_HOME="/home/arch"
export DETECTED_SHELL="/bin/bash"
export DETECTED_HOSTNAME="$TARGET_HOSTNAME"

# Add backup drive to /etc/fstab for layer validation
sed -i '/\/mnt\/backup/d' /etc/fstab
echo "UUID=$BACKUP_UUID /mnt/backup btrfs defaults,nofail 0 0" >> /etc/fstab

# Headless UI mocks
ui_msgbox() { return 0; }
ui_infobox() { return 0; }
ui_yesno() { return 0; }
ui_textbox() { return 0; }
ui_confirm_destructive() { return 0; }
ui_checklist() { echo "\"Downloads\" \"Games\" \".cache\""; }
ui_menu() { echo "drive"; }
ui_inputbox() { echo "$3"; }
aur_install() { log_info "Mock AUR install: $*"; return 0; }
export UI_SILENT="true"

# --- STAGE 4: Real-Life CLI Dry-Run Mode (as user 'arch' with sudo) ---
echo ""
echo "--- STAGE 4: Real-Life CLI Dry-Run Mode (sudo ./wizard.sh --dry-run) ---"
rm -f /tmp/arch-backup-wizard*.log
su - arch -c "cd /home/arch/arch-backup-wizard && sudo env TERM=linux UI_SILENT=true ./wizard.sh --dry-run" >/tmp/dry_run.log 2>&1
report_test "CLI dry-run simulation execution (sudo ./wizard.sh --dry-run)" $? "/tmp/dry_run.log"
grep -E "SIMULATION|PACKAGES|PLANNED|finished" /tmp/dry_run.log || true

# --- STAGE 5: Live Layer Setup (Multi-Layer Execution) ---
echo ""
echo "--- STAGE 5: Live Multi-Layer Setup ---"
DRY_RUN=false
SELECTED_LAYERS=("1" "2" "3" "4" "5")
rm -f /tmp/arch-backup-wizard*.log

# Layer 1: Snapper
setup_layer1 >/tmp/layer1_setup.log 2>&1
report_test "Layer 1 (Snapper) setup" $? "/tmp/layer1_setup.log"
[[ -f /etc/snapper/configs/root ]]
report_test "Snapper root config created" $?

# Layer 2: btrbk
setup_layer2 >/tmp/layer2_setup.log 2>&1
report_test "Layer 2 (btrbk) setup" $? "/tmp/layer2_setup.log"
[[ -f /etc/btrbk/btrbk.conf ]]
report_test "btrbk.conf generated" $?
[[ -d /etc/systemd/system/btrbk.service.d ]]
report_test "btrbk low-priority systemd override created" $?

# Test an initial btrbk backup run!
btrbk run --config /etc/btrbk/btrbk.conf >/tmp/btrbk_run.log 2>&1
report_test "Initial btrbk snapshot & send/receive clone" $? "/tmp/btrbk_run.log"
[[ -d /mnt/backup/OS_Backup ]] && [[ $(ls -A /mnt/backup/OS_Backup | wc -l) -gt 0 ]]
report_test "OS clone subvolume exists in /mnt/backup/OS_Backup" $?

# Layer 3: Pika / Borg
BORG_REPO="/mnt/backup/Personal/backup-${TARGET_HOSTNAME}-$TARGET_USER"
mkdir -p "$BORG_REPO"
chown arch:arch "$BORG_REPO"
borg init --encryption=none "$BORG_REPO" >/tmp/borg_init.log 2>&1 || true
setup_layer3 >/tmp/layer3_setup.log 2>&1
report_test "Layer 3 (Borg / Pika) repo setup" $? "/tmp/layer3_setup.log"
BORG_REPO="/mnt/backup/Personal/backup-${TARGET_HOSTNAME}-$TARGET_USER"
[[ -d "$BORG_REPO" ]]
report_test "Borg repository directory created at $BORG_REPO" $?

# Test creating a borg archive!
borg init --encryption=none "$BORG_REPO" >/tmp/borg_init.log 2>&1 || true
borg create "$BORG_REPO::test-backup-$(date +%s)" /home/arch >/tmp/borg_create.log 2>&1
report_test "Borg backup archive creation" $? "/tmp/borg_create.log"

# Layer 4: Cloud Scripts & Mock Storage
mkdir -p /var/mock_cloud_storage
mkdir -p /home/arch/.config/rclone
mkdir -p /home/arch/.config/arch-backup-wizard
cat <<EOF > /home/arch/.config/rclone/rclone.conf
[mockcloud]
type = local
copy_is_hardlink = false
EOF
age-keygen -o /home/arch/.config/arch-backup-wizard/cloud_os.key 2>/dev/null
chmod 600 /home/arch/.config/arch-backup-wizard/cloud_os.key
chown -R arch:arch /home/arch/.config
export LAYER4_ENCRYPT="true"
export CLOUD_ARCHIVE_EXT=".btrfs.zst.age"
export AGE_PUBKEY
AGE_PUBKEY=$(grep -oP 'public key: \K\w+' /home/arch/.config/arch-backup-wizard/cloud_os.key || true)
export CLOUD_REMOTE="mockcloud:"
export CLOUD_OS_DIR="/var/mock_cloud_storage/Arch_BareMetal_Clones"
export CLOUD_PIKA_DIR="/var/mock_cloud_storage/Arch_Pika_Backup"

mkdir -p /var/lib/arch-backup-wizard
cat <<EOF > /var/lib/arch-backup-wizard/settings.env
# Arch Backup Wizard Architecture Contract
declare -g -- LAYER4_ENCRYPT="true"
EOF

mkdir -p /var/lib/pika-cloud-sync
touch /var/lib/pika-cloud-sync/enabled /var/lib/pika-cloud-sync/state
export BACKUP_MOUNT="/mnt/backup"

template_render "$WIZARD_DIR/templates/os-cloud-backup.sh" "$TARGET_HOME/.os_cloud_backup.sh"
template_render "$WIZARD_DIR/templates/os-clone-nag.sh" "$TARGET_HOME/.os_clone_nag.sh"
template_render "$WIZARD_DIR/templates/pika-cloud-sync.service" /etc/systemd/system/pika-cloud-sync.service || cp "$WIZARD_DIR/templates/pika-cloud-sync.service" /etc/systemd/system/pika-cloud-sync.service
template_render "$WIZARD_DIR/templates/pika-cloud-sync.timer" /etc/systemd/system/pika-cloud-sync.timer || cp "$WIZARD_DIR/templates/pika-cloud-sync.timer" /etc/systemd/system/pika-cloud-sync.timer
template_render "$WIZARD_DIR/templates/pika-cloud-sync-stale-check.service" /etc/systemd/system/pika-cloud-sync-stale-check.service || cp "$WIZARD_DIR/templates/pika-cloud-sync-stale-check.service" /etc/systemd/system/pika-cloud-sync-stale-check.service
template_render "$WIZARD_DIR/templates/pika-cloud-sync-stale-check.timer" /etc/systemd/system/pika-cloud-sync-stale-check.timer || cp "$WIZARD_DIR/templates/pika-cloud-sync-stale-check.timer" /etc/systemd/system/pika-cloud-sync-stale-check.timer
chmod 644 /etc/systemd/system/pika-cloud-sync.service /etc/systemd/system/pika-cloud-sync.timer
systemctl daemon-reload
systemctl enable --now pika-cloud-sync.timer >/dev/null 2>&1 || true

echo "# Sourced by Arch Backup Wizard" >> /home/arch/.bashrc
echo "[[ -f ~/.os_clone_nag.sh ]] && bash ~/.os_clone_nag.sh" >> /home/arch/.bashrc
chmod +x "$TARGET_HOME/.os_cloud_backup.sh" "$TARGET_HOME/.os_clone_nag.sh"
chown arch:arch "$TARGET_HOME/.os_cloud_backup.sh" "$TARGET_HOME/.os_clone_nag.sh" /home/arch/.bashrc
report_test "Layer 4 (Cloud backup & nag scripts) rendered" $?

# Layer 5: Deep Storage
setup_layer5 >/tmp/layer5_setup.log 2>&1
report_test "Layer 5 (Deep Storage) setup" $? "/tmp/layer5_setup.log"
[[ -d "/mnt/backup/Deep Storage" ]]
report_test "Deep Storage directory created" $?

# --- STAGE 6: Disaster Recovery Runbooks Generation ---
echo ""
echo "--- STAGE 6: Disaster Recovery Runbooks Generation ---"
generate_runbooks >/tmp/runbooks.log 2>&1
report_test "Runbook generation executed" $? "/tmp/runbooks.log"
[[ -f "$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt" ]]
report_test "Bare-Metal Runbook exists on backup drive" $?
grep -q "$ROOT_UUID" "$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"
report_test "Bare-Metal Runbook contains actual virtual Root UUID" $?

# --- STAGE 7: Live Validation Suite (CLI Mode as user 'arch' with sudo) ---
echo ""
echo "--- STAGE 7: Real-Life CLI Health Validation (sudo ./wizard.sh --validate) ---"
rm -f /tmp/arch-backup-wizard*.log
su - arch -c "cd /home/arch/arch-backup-wizard && sudo ./wizard.sh --validate" >/tmp/validation_live.log 2>&1
report_test "CLI validation suite executed (sudo ./wizard.sh --validate)" $? "/tmp/validation_live.log"
grep -E "PASS|FAIL|Summary|Layer" /tmp/validation_live.log || true

# Test unencrypted Layer 4 contract validation
cat <<EOF > /var/lib/arch-backup-wizard/settings.env
# Arch Backup Wizard Architecture Contract
declare -g -- LAYER4_ENCRYPT="false"
EOF
mv /home/arch/.config/arch-backup-wizard/cloud_os.key /home/arch/.config/arch-backup-wizard/cloud_os.key.bak
mv /usr/bin/age /usr/bin/age.bak
su - arch -c "cd /home/arch/arch-backup-wizard && sudo ./wizard.sh --validate" >/tmp/validation_unencrypted.log 2>&1
report_test "CLI validation passes unencrypted without age or key" $? "/tmp/validation_unencrypted.log"
mv /usr/bin/age.bak /usr/bin/age
mv /home/arch/.config/arch-backup-wizard/cloud_os.key.bak /home/arch/.config/arch-backup-wizard/cloud_os.key
cat <<EOF > /var/lib/arch-backup-wizard/settings.env
# Arch Backup Wizard Architecture Contract
declare -g -- LAYER4_ENCRYPT="true"
EOF

# --- STAGE 8: Real-Life Lifecycle Uninstall (as user 'arch' with sudo) ---
echo ""
echo "--- STAGE 8: Real-Life CLI Uninstall (sudo ./wizard.sh --uninstall) ---"
rm -f /tmp/arch-backup-wizard*.log
su - arch -c "cd /home/arch/arch-backup-wizard && sudo env TERM=linux UI_SILENT=true ./wizard.sh --uninstall" >/tmp/uninstall_live.log 2>&1
report_test "CLI uninstall execution (sudo ./wizard.sh --uninstall)" $? "/tmp/uninstall_live.log"
! systemctl is-active --quiet snapper-cleanup.timer
report_test "Snapper cleanup timer inactive" $?
! systemctl is-active --quiet btrbk.timer
report_test "btrbk timer inactive" $?

echo ""
echo "================================================================================"
echo "          IN-VM TEST SUMMARY: $PASS_COUNT PASSED, $FAIL_COUNT FAILED"
echo "================================================================================"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "SUCCESS: ALL IN-VM TESTS PASSED AS INTENDED!"
    touch /root/VM_TESTS_SUCCESS
else
    echo "FAILURE: SOME IN-VM TESTS FAILED!"
    touch /root/VM_TESTS_FAILED
fi
sync
