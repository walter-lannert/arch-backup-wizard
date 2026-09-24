#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/runbooks.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_helper.bash
source "$SCRIPT_DIR/test_helper.bash"
source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/runbooks.sh"

# ── Override UI functions (defined in lib/ui.sh) to avoid interactive prompts ─
ui_msgbox() {
    # shellcheck disable=SC2034
    UI_MSGBOX_TITLE="$1"
    UI_MSGBOX_BODY="$2"
    return 0
}

ui_yesno() {
    return 0
}

# ── Helper: set common environment for runbook tests ──────────────────────────
_setup_runbook_env() {
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    export MANIFEST_FILE="$TEST_TEMP_DIR/manifest.txt"
    export ORIG_MANIFEST="$TEST_TEMP_DIR/orig_manifest.txt"
    export DRY_RUN=true
    export VALIDATE=false

    export DETECTED_USER="testuser"
    export DETECTED_HOME="$TEST_TEMP_DIR/home"
    export DETECTED_ROOT_UUID="aaaa-bbbb-cccc"
    export DETECTED_EFI_UUID="dddd-eeee-ffff"
    export DETECTED_BOOTLOADER="GRUB"
    export DETECTED_HOSTNAME="testhost"
    export DETECTED_ROOT_SUBVOL="@"
    export DETECTED_SUBVOL_LAYOUT="standard"
    export DETECTED_DISTRO="Arch Linux"
    export DETECTED_SUBVOLUMES="@
@home
@snapshots"
    export DETECTED_SUBVOL_MOUNTS="/home:@home"
    export DETECTED_EFI_MOUNT="/boot"
    export BACKUP_UUID="1111-2222-3333"
    export CLOUD_REMOTE=""
    export CLOUD_OS_DIR=""
    export CLOUD_PIKA_DIR=""
    export CLOUD_AGE_KEY=""
    export BACKUP_SRC_DIR="/mnt/backup/OS_Backup"

    export WIZARD_DIR="$TEST_TEMP_DIR/wizard"
    mkdir -p "$WIZARD_DIR/templates"

    export BACKUP_MOUNT="$TEST_TEMP_DIR/backup"
    mkdir -p "$BACKUP_MOUNT"

    mock_cmd pacman 'exit 0'
    mock_cmd hostname 'echo testhost'
    mock_cmd chown 'exit 0'
}

# ── Test 1: Happy path — Layer 1 (Snapper) runbook generation ────────────────

test_layer1_runbook_happy_path() {
    _setup_runbook_env
    SELECTED_LAYERS=("1")

    cat <<'TMPL' > "$WIZARD_DIR/templates/rollback-runbook.txt"
# Layer 1 Rollback Runbook
Host: {{HOSTNAME_VAL}}
User: {{USERNAME}}
Root UUID: {{ROOT_UUID}}
EFI UUID: {{EFI_UUID}}
Bootloader: {{BOOTLOADER}}
Backup Mount: {{BACKUP_MOUNT}}
TMPL

    generate_runbooks

    local out="$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt"
    assert_file_exists "$out" "Layer 1 runbook should be generated"

    local content
    content=$(<"$out")
    assert_match "Host: testhost" "$content" "Hostname substituted"
    assert_match "User: testuser" "$content" "Username substituted"
    assert_match "Root UUID: aaaa-bbbb-cccc" "$content" "Root UUID substituted"
    assert_match "EFI UUID: dddd-eeee-ffff" "$content" "EFI UUID substituted"
    assert_match "Bootloader: GRUB" "$content" "Bootloader substituted"
}

# ── Test 2: Happy path — Layer 2 (BTRBK) bare-metal runbook ──────────────────

test_layer2_runbook_happy_path() {
    _setup_runbook_env
    SELECTED_LAYERS=("2")

    cat <<'TMPL' > "$WIZARD_DIR/templates/bare-metal-runbook.txt"
# Bare-Metal Recovery
Distro: {{DISTRO}}
Root UUID: {{ROOT_UUID}}
EFI UUID: {{EFI_UUID}}
Bootloader: {{BOOTLOADER}}
Kernel: {{KERNEL_PKGS}}
TMPL

    mock_cmd pacman 'echo linux-cachyos linux-cachyos-headers ucode_amd'

    generate_runbooks

    local out="$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt"
    assert_file_exists "$out" "Bare-metal runbook should be generated"

    local content
    content=$(<"$out")
    assert_match "Distro: Arch Linux" "$content" "Distro substituted"
    assert_match "Root UUID: aaaa-bbbb-cccc" "$content" "Root UUID substituted"
    assert_match "Bootloader: GRUB" "$content" "Bootloader substituted"
    assert_match "linux-cachyos" "$content" "Kernel packages detected"
}

# ── Test 3: Edge case — Missing template files (graceful degradation) ────────

test_missing_template_graceful() {
    _setup_runbook_env
    SELECTED_LAYERS=("1" "2")
    # Intentionally do NOT create any template files

    generate_runbooks

    assert_failure "test -f '$BACKUP_MOUNT/Layer1_Snapper_Rollback_Runbook.txt'" \
        "Layer 1 runbook should NOT exist without template"
    assert_failure "test -f '$BACKUP_MOUNT/Bare_Metal_Recovery_Runbook.txt'" \
        "Layer 2 runbook should NOT exist without template"

    assert_match "not found" "$UI_MSGBOX_BODY" "Summary should mention missing templates"
}

# ── Test 4: Edge case — No layers selected ────────────────────────────────────

test_no_layers_selected() {
    _setup_runbook_env
    SELECTED_LAYERS=()

    generate_runbooks

    assert_match "No recovery runbooks" "$UI_MSGBOX_BODY" \
        "Should report no runbooks generated"
}

# ── Test 5: Failure path — BACKUP_MOUNT path is a file (mkdir fails) ─────────

test_backup_mount_is_file() {
    _setup_runbook_env
    SELECTED_LAYERS=("1")

    echo "template" > "$WIZARD_DIR/templates/rollback-runbook.txt"

    # Replace BACKUP_MOUNT directory with a regular file
    rm -rf "$BACKUP_MOUNT"
    echo "I am a file, not a directory" > "$BACKUP_MOUNT"

    local rc=0
    generate_runbooks || rc=$?
    assert_eq "1" "$rc" "generate_runbooks should fail when BACKUP_MOUNT is a file"
}

# ── Test 6: Happy path — Cloud runbook with rclone upload ─────────────────────

test_cloud_runbook_with_upload() {
    _setup_runbook_env
    export DRY_RUN=false
    export CLOUD_REMOTE="myremote:"
    export CLOUD_OS_DIR="/backups/os"
    export CLOUD_PIKA_DIR="/backups/pika"
    export CLOUD_AGE_KEY="/root/cloud_os.key"
    SELECTED_LAYERS=("2" "4")

    cat <<'TMPL' > "$WIZARD_DIR/templates/cloud-recovery-runbook.txt"
# Cloud Recovery Runbook
Remote: {{CLOUD_REMOTE}}
OS Dir: {{CLOUD_OS_DIR}}
Age Key: {{CLOUD_AGE_KEY}}
TMPL
    cat <<'TMPL' > "$WIZARD_DIR/templates/bare-metal-runbook.txt"
# Bare-Metal
Root: {{ROOT_UUID}}
TMPL

    # Mock rclone to log invocation
    # shellcheck disable=SC2016
    mock_cmd rclone 'echo "rclone $*" >> "$HOME/rclone_calls.log"'
    # Mock sudo (run_as_user calls sudo -u <user> <cmd>...)
    # shellcheck disable=SC2016
    mock_cmd sudo 'shift 2; exec "$@"'

    generate_runbooks

    local out="$BACKUP_MOUNT/Cloud_Recovery_Runbook.txt"
    assert_file_exists "$out" "Cloud runbook should be generated"

    local content
    content=$(<"$out")
    assert_match "Remote: myremote:" "$content" "Cloud remote substituted"
    assert_match "OS Dir: /backups/os" "$content" "Cloud OS dir substituted"
    assert_match "Age Key: /root/cloud_os.key" "$content" "Age key substituted"

    # Verify rclone was invoked for upload (bounded polling for resilience)
    local rclone_log=""
    for _ in {1..20}; do
        if [[ -f "$HOME/rclone_calls.log" ]]; then
            rclone_log=$(<"$HOME/rclone_calls.log")
            [[ -n "$rclone_log" ]] && break
        fi
        sleep 0.1
    done
    assert_file_exists "$HOME/rclone_calls.log" "rclone should have been called"
    assert_match "copyto" "$rclone_log" "rclone copyto should be used for upload"
}

# ── Run tests ─────────────────────────────────────────────────────────────────

echo "=== Running tests for lib/runbooks.sh ==="
run_test test_layer1_runbook_happy_path "Layer 1 (Snapper) runbook happy path"
run_test test_layer2_runbook_happy_path "Layer 2 (BTRBK) bare-metal runbook happy path"
run_test test_missing_template_graceful "Missing template graceful degradation"
run_test test_no_layers_selected "No layers selected"
run_test test_backup_mount_is_file "BACKUP_MOUNT is a file (failure path)"
run_test test_cloud_runbook_with_upload "Cloud runbook with rclone upload"
test_summary
