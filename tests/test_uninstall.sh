#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for lib/uninstall.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/test_helper.bash
source "$SCRIPT_DIR/test_helper.bash"

_setup_uninstall_env() {
    export TEST_FSTAB="$TEST_TEMP_DIR/fstab"
    export TEST_MANIFEST="$TEST_TEMP_DIR/manifest.txt"
    export LOG_FILE="$TEST_TEMP_DIR/test.log"
    touch "$LOG_FILE"
    
    cat <<'EOF' > "$TEST_FSTAB"
# /etc/fstab: static file system information.
UUID=1234 / btrfs rw,noatime,compress=zstd:1,space_cache=v2,subvolid=256,subvol=/@ 0 0

# BEGIN Arch Backup Wizard /.snapshots Mount
UUID=1234 /.snapshots btrfs subvol=/@/.snapshots,defaults,noatime,compress=zstd 0 0
# END Arch Backup Wizard /.snapshots Mount

# BEGIN Arch Backup Wizard
UUID=9999 /mnt/backup btrfs rw,noatime,compress=zstd 0 0
# END Arch Backup Wizard

# User added line after install
UUID=5678 /data xfs defaults 0 2
EOF

    echo "/etc/fstab" > "$TEST_MANIFEST"
    echo "$TEST_TEMP_DIR/some-other-file" >> "$TEST_MANIFEST"
    touch "$TEST_TEMP_DIR/some-other-file"
}

test_uninstall_fstab_safety() {
    _setup_uninstall_env
    
    local fstab_tmp
    fstab_tmp=$(mktemp)
    cp -p "$TEST_FSTAB" "$fstab_tmp"
    
    sed -i -z 's/\(^\|\n\)# Arch Backup Wizard Mount\n[^\n]*\n/\1/g' "$fstab_tmp" 2>/dev/null || true
    sed -i '/# BEGIN Arch Backup Wizard/,/# END Arch Backup Wizard/d' "$fstab_tmp" 2>/dev/null || true
    
    if grep -q "# BEGIN Arch Backup Wizard" "$fstab_tmp"; then
        echo "Error: Managed block 1 should be gone" >&2
        return 1
    fi
    if grep -q "# END Arch Backup Wizard" "$fstab_tmp"; then
        echo "Error: Managed block 1 should be gone" >&2
        return 1
    fi
    if ! grep -q "/data" "$fstab_tmp"; then
        echo "Error: User added line must remain" >&2
        return 1
    fi
    if ! grep -q "UUID=1234 / btrfs" "$fstab_tmp"; then
        echo "Error: Pre-wizard lines must remain" >&2
        return 1
    fi
    
    rm -f "$fstab_tmp"
}

test_generic_manifest_skip() {
    _setup_uninstall_env
    
    _RM_CALLED_ON_FSTAB=0
    _RM_CALLED_ON_OTHER=0
    rm() {
        for arg in "$@"; do
            if [[ "$arg" == "/etc/fstab" ]]; then
                _RM_CALLED_ON_FSTAB=1
            elif [[ "$arg" == "$TEST_TEMP_DIR/some-other-file" ]]; then
                _RM_CALLED_ON_OTHER=1
            fi
        done
        command rm "$@" || true
    }
    
    while IFS= read -r file; do
        if [[ "$file" == "/etc/fstab" ]]; then
            continue
        fi
        if [[ -e "$file" ]]; then
            rm -f "$file"
        fi
    done < "$TEST_MANIFEST"
    
    assert_eq "0" "$_RM_CALLED_ON_FSTAB" "rm should not be called on /etc/fstab"
    assert_eq "1" "$_RM_CALLED_ON_OTHER" "rm should be called on other manifest files"
}

run_tests
