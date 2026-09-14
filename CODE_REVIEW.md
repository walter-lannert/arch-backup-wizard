# Code Review — Arch Backup Wizard

**Mode:** Boy Scout Rule ("leave the code cleaner than you found it").
**Focus:** the last commit that touched code — `0d4948d` *"feat: apply
comprehensive code review refactors and fixes"* (brought into `bgra_review` by
merge `e477e30`).
**Date:** 2026-09-14 · **Reviewer:** BGRA
**Scope:** `wizard.sh`, `lib/*.sh`, `templates/*`, `README.md`.
**Note on "enpasys":** no symbol, file, or string by that name exists in the
repository (`grep -r enpasys` → no match). Interpreted as *"in place / on the
last commit"*; review is therefore scoped to that commit's changes and the code
around them.

---

## TL;DR

The last commit was a large `shfmt`-style reformat (whitespace, case-statement
alignment, `>> $F` → `>>"$F"`, blank-line removal) plus a handful of genuine
logic fixes. The mechanical work is clean and consistent. A few spots,
however, were *missed* by that same pass and will now actively **break the
`make check` (ShellCheck) gate the commit's own README advertises**, plus a
couple of robustness/consistency nits that a passing developer should tidy up.

All scripts pass `bash -n`. No syntax errors.

| # | Severity | File:line | Title |
|---|----------|-----------|-------|
| 1 | **High** | `wizard.sh:171`, `lib/packages.sh:121` | Unquoted word-split loops trip SC2086 → `make check` fails |
| 2 | **Medium** | `lib/uninstall.sh:67` | `rm -rf` used on a single *file* |
| 3 | **Medium** | `lib/uninstall.sh:122-125` | Nag cleanup runs 3 `sed` passes; broad pattern can delete user lines |
| 4 | **Medium** | `templates/os-cloud-backup.sh:6,19,23,27` | Unquoted templated paths break on mount points with spaces |
| 5 | **Medium** | `templates/pika-cloud-sync.service:12` | `rclone sync` (destructive mirror) for offsite backup — confirm intent |
| 6 | **Low** | `lib/detect.sh:66-68` | `findmnt` assignments lack `|| echo ""` guard (inconsistent w/ line 69) |
| 7 | **Low** | `README.md:157` | `--validate` example dropped `sudo`, inconsistent with the rest |
| 8 | **Low** | `templates/os-cloud-backup.sh` | No `set -euo pipefail`; "latest by mtime" may not be sendable |

---

## 1. `make check` currently fails on the reformat it shipped (High)

The commit's README (line 208) advertises `make check` (ShellCheck) and
`shfmt -i 4 -w .`. But two loops still split an unquoted variable, which
ShellCheck reports as **SC2086**, and `.shellcheckrc` does *not* disable it
(it only disables `SC2034`, `SC1091`, `SC2088`):

```bash
# wizard.sh:171     (inside select_layers)
for tag in $result; do

# lib/packages.sh:121     (inside install_layer_packages)
for pkg in $all_pkgs; do
```

Both are *intentional* word-splitting (a list of tags / a list of package
names). The correct, self-documenting fix is a scoped directive, **not** adding
`SC2086` to the global config (that would hide real quoting bugs elsewhere):

```bash
# shellcheck disable=SC2086    # intentional word-split of a space/newline-separated list
for tag in $result; do
```

`for l in "$LAYER_BTRBK" ...` at `wizard.sh:184` is fine (quoted literals) and
needs no change. This is the single most impactful cleanup: it un-breaks the
lint gate.

---

## 2. `rm -rf` on a single file (Medium) — `lib/uninstall.sh:67`

```bash
rm -rf "$btrbk_override"       # $btrbk_override = "$BTRBK_OVERRIDE_DIR/override.conf" (a file)
```

`-rf` on a known single file obscures intent and is the exact pattern
reviewers flag (it would happily recurse if the path were ever wrong). It is a
file, so:

```bash
rm -f "$btrbk_override"
rmdir "$BTRBK_OVERRIDE_DIR" 2>/dev/null || true
```

The following `rmdir` already handles the empty dir, so the intent is clear once
the flag is narrowed.

---

## 3. Over-broad nag-script cleanup (Medium) — `lib/uninstall.sh:122-125`

```bash
sed -i '/# Arch Backup Wizard OS Clone Nag BEGIN/,/# Arch Backup Wizard OS Clone Nag END/d' "$rc"
sed -i '/Arch Backup Wizard OS Clone Nag/d' "$rc"       # fallback for old installs
sed -i '/os_clone_nag/d' "$rc"                          # also strips ANY line mentioning os_clone_nag
```

- Three passes over the same file can be one `sed -i -e ... -e ... -e ...`.
- The last pattern `/os_clone_nag/d` will delete a user's *unrelated* line that
  merely contains the substring (e.g. a comment or a third-party tool). The
  sentinel-based first pass is the correct, safe primary path; the broad
  fallback is a footgun.

Suggested:

```bash
sed -i \
    -e '/# Arch Backup Wizard OS Clone Nag BEGIN/,/# Arch Backup Wizard OS Clone Nag END/d' \
    -e '/# Arch Backup Wizard OS Clone Nag/d' \
    "$rc"
```

(Keep the `/os_clone_nag/` fallback only if a pre-sentinel install format still
exists; otherwise drop it. If kept, scope it to the exact generated `nag_line`
rather than the bare substring.)

---

## 4. Unquoted templated paths break on mount points with spaces (Medium)

`templates/os-cloud-backup.sh` interpolates `{{BACKUP_MOUNT}}` into unquoted
shell positions:

```bash
LATEST_SNAP=$(ls -t {{BACKUP_MOUNT}}/OS_Backup | head -n 1)
sudo btrfs send "{{BACKUP_MOUNT}}/OS_Backup/$LATEST_SNAP" | ... > "{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst"
rclone copy "{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst" "{{CLOUD_REMOTE}}{{CLOUD_OS_DIR}}" -P
rm "{{BACKUP_MOUNT}}/Cloud_Archive.btrfs.zst"
```

The wizard itself is space-aware (it escapes spaces in the fstab entry,
`fstab_mount="${BACKUP_MOUNT// /\\040}"` in `wizard.sh`), but the *generated*
script is not: a backup mount with a space (e.g. `/mnt/My Drive`) word-splits at
`ls -t {{BACKUP_MOUNT}}/OS_Backup`. Quote every interpolation in the template,
and add `set -euo pipefail` at the top of the generated script (see #8).


---

## 5. Destructive `rclone sync` for offsite backup — confirm intent (Medium)

`templates/pika-cloud-sync.service:12`:

```
ExecStart=/usr/bin/rclone sync "{{BACKUP_MOUNT}}/Personal" "{{CLOUD_REMOTE}}{{CLOUD_PIKA_DIR}}" -v
```

The commit correctly added a warning comment that `sync` mirrors (deletes
remote-only files). But for *offsite* data this is the one setting that can
irreversibly delete cloud data if the local Borg repo is briefly incomplete or
partially pruned. The unit already uses `Nice=19`/`IOSchedulingClass=idle`, so
a non-destructive `copy` (optionally `--delete-duplicates`) is usually the safer
offsite default. This is a **design decision**, not a bug — flag it so the
choice is explicit and user-facing, and align the "weekly sync" wording in the
timer/summary with whichever verb is actually chosen.

---

## 6. Inconsistent `findmnt` guards (Low) — `lib/detect.sh:66-69`

```bash
DETECTED_ROOT_FS=$(findmnt -n -o FSTYPE /)
DETECTED_ROOT_DEV=$(findmnt -n -o SOURCE /)
DETECTED_ROOT_UUID=$(findmnt -n -o UUID /)
DETECTED_ROOT_SUBVOL=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+' || echo "")
```

Line 69 already guards against failure, but 66-68 do not. Under
`set -euo pipefail` (set in `wizard.sh`) a non-zero `findmnt` would abort
detection before the friendly "BTRFS required" dialog. Make all four consistent:

```bash
DETECTED_ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")
DETECTED_ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
DETECTED_ROOT_UUID=$(findmnt -n -o UUID / 2>/dev/null || echo "")
```

---

## 7. README `sudo` convention is now inconsistent (Low) — `README.md:157`

The commit changed the `--validate` example to drop `sudo`:

```
./wizard.sh --validate 1,3,4
```

…but every other invocation keeps it (`sudo ./wizard.sh` L46/54,
`sudo ./wizard.sh --uninstall` L163, `sudo ./wizard.sh --dry-run` L209).
`require_root` intentionally allows non-root for `--validate`/`--dry-run`, so
the drop is *defensible* — but `--validate` runs `run_detection`, which
invokes root-only steps (`btrfs subvolume list /`, mount lookups), so in
practice it should be run as root to get meaningful results. Pick one convention
and apply it uniformly (either all `sudo`, or explicitly document that
`--validate`/`--dry-run` are the two non-root modes).

---

## 8. Generated nag/cloud scripts lack hardening (Low)

`templates/os-clone-nag.sh` and `templates/os-cloud-backup.sh` are
`#!/bin/bash` with no `set -euo pipefail`. In particular
`os-cloud-backup.sh`:

- `LATEST_SNAP=$(ls -t .../OS_Backup | head -n 1)` picks the snapshot newest by
   *mtime*, which is not guaranteed to be a sendable leaf snapshot;
   `btrfs send` can fail with "parent not found" on non-leaf snapshots. Prefer
   `btrfs subvolume list` + `--parent`, or at least `|| true` so the script is
  diagnosable.
- `{{DETECTED_TERMINAL_CMD}}` can render empty on a system with no detected
  terminal; guard with a default (the wizard already computes
  `${DETECTED_TERMINAL_CMD:-xterm -e}` in `layer4_cloud.sh:174` — reuse that at
  render time so the template never emits a bare empty token).

---

## Positives (already clean — worth keeping)

- **Single source of truth:** `layer_selected()` is defined only in
   `lib/common.sh:74` and its "do not redefine" contract holds (verified across
   `runbooks.sh`/`validate.sh`).
- **Sourcing hygiene:** `set -euo pipefail` was correctly *removed* from the
  sourced libs (a `set -e` in a sourced file infects the parent) and kept only
  in the top-level `wizard.sh:8`.
- **Startup ordering fix:** moving `ensure_dialog`/`detect_dialog` *after* the
   `--uninstall`/`--validate` branches (`wizard.sh:517-519`) so headless modes no
  longer force a GUI install — `uninstall.sh`/`validate.sh` self-detect the
  backend.
- **Consistent failure contract:** layer setup now uniformly
  `log_error "..."; return 1` (e.g. the new `mkdir ... || { return 1; }`
  guards in layers 1/2/4/5), matching the documented "never call `die()` inside
  a layer" rule.
- **Quoting & redirect cleanup** (`>>"$F"`, `cat >>"$rc"` etc.) is uniform and
  ShellCheck-friendly across the diff.
- All 13 scripts pass `bash -n`.

---

## Suggested follow-up (smallest clean commit)

1. Add the two `# shellcheck disable=SC2086` directives (#1) — restores
   `make check`.
2. Narrow `rm -rf`→`rm -f` and collapse the `sed` passes (#2, #3).
3. Quote the templated paths + add `set -euo pipefail` to the two generated
   scripts (#4, #8).
4. Decide `sync` vs `copy` for offsite and document it (#5).
5. Make `findmnt` guards consistent (#6) and fix the README `sudo` convention
   (#7).

Each item is independently mergeable and keeps the Boy Scout spirit: the last
commit cleaned up the formatting; these finish the job on the lint gate and the
robustness edges it left behind.

