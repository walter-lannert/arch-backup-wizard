# Code Review — arch-backup-wizard

**Lens:** Boy Scout Rule — *"Always leave the code cleaner than you found it."*
**Scope:** `wizard.sh`, `lib/*.sh`, `templates/*`, build/CI config.
**Reviewer focus:** small, safe, high-leverage improvements. No big rewrites.
**Status:** Findings only. No source changes applied yet.

---

## 0. TL;DR

The wizard is well-structured, defensively written, and idempotent by design.
The biggest wins are **removing dead code** and **fixing one portability bug**
in `detect.sh`. Everything below is a small, self-contained change.

| # | Severity | Area | One-liner |
|---|----------|------|-----------|
| 1 | Bug | `lib/detect.sh:152` | `grep '^\s*#'` — GNU `\s` is not portable; use `[[:space:]]` |
| 2 | Cleanup | `lib/detect.sh:264` | `format_backup_drive_choices()` is dead code |
| 3 | Cleanup | `lib/detect.sh:164` | `DETECTED_MACHINE_ID` set, never read |
| 4 | Cleanup | `lib/common.sh:210` | `user_unit_is_enabled()` never called |
| 5 | Cleanup | `lib/packages.sh:15` | `pkg_in_repos()` never called |
| 6 | Quality | `lib/layer3_pika.sh:98` | `eval` of dialog output — use `read -ra` |
| 7 | Robust | `wizard.sh:345` | fstab presence check is a loose substring match |
| 8 | Edge | `wizard.sh:314` | whole-disk regex misses multi-part names |
| 9 | Cosmetic | `wizard.sh:30-80` | Inconsistent indentation in `parse_args` |
| 10 | Consistency | all `lib/*.sh` | `set -euo pipefail` sits mid-file, not at top |

Nothing here is blocking. Pick the ones you value most.

---

## 1. Portability bug — `grep -v '^\s*#'`      *(Bug, high value)*

**`lib/detect.sh:152`**
```bash
done < <(grep -v '^\s*#' /etc/fstab | grep -v '^\s*$')
```

`\s` is a GNU extension; it is **not** portable and is not POSIX. The rest of
the codebase already uses the correct form — e.g. `lib/validate.sh:280`:
```bash
grep -v '^[[:space:]]*#'
```

The inconsistency means this one line will behave differently (or warn) on a
non-GNU `grep`, and it is the only place using `\s` in the whole tree.
**Fix — match the convention already used 40 lines away:**
```bash
done < <(grep -v '^[[:space:]]*#' /etc/fstab | grep -v '^[[:space:]]*$')
```

---

## 2. Dead code — `format_backup_drive_choices()`      *(Cleanup)*

**`lib/detect.sh:264-286`** — this function is defined but **never called**.
The live path (`select_backup_drive`, `wizard.sh:217-249`) builds the radiolist
inline instead, so this is a stale duplicate of that logic.

**Fix:** delete the function and its comment block (`# Build dialog-formatted
list of candidate backup partitions ...` through the closing brace at line 286).
Removing it also drops the only reference to the `_type` throwaway read pattern
in `detect.sh`.

---

## 3. Dead detection value — `DETECTED_MACHINE_ID`      *(Cleanup)*

**`lib/detect.sh:164`**
```bash
DETECTED_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
```
Set here, read **nowhere** in the tree. Either wire it into a runbook
(useful for offsite recovery identification) or remove the line. Removing is
the lower-risk choice.

---

## 4. Dead helper — `user_unit_is_enabled()`      *(Cleanup)*

**`lib/common.sh:210-212`** — defined, never invoked. The only user-unit check
that actually runs is the inline `run_as_user systemctl --user is-enabled` in
`layer4_cloud.sh`. Remove this wrapper, or use it in `validate.sh` to confirm
`pika-cloud-sync.timer` for the real user (a small validation gain).

---

## 5. Dead helper — `pkg_in_repos()`      *(Cleanup)*

**`lib/packages.sh:15-17`** — defined, never called. Remove it, or use it in
`pkg_install` to give a clearer error when a package name is wrong (a nice
DX improvement if you keep it).

---

## 6. Avoid `eval` on dialog output — `read -ra`      *(Quality)*

**`lib/layer3_pika.sh:98`**
```bash
eval "selected_exclusions=($raw_exclusions)"
```

`raw_exclusions` is the raw stdout of `ui_checklist`. Today the tags are
hardcoded, so injection risk is low — but `eval` on external-command output is a
code smell and it will silently mangle any tag containing shell metacharacters.
The intent is word-splitting into an array; `read -ra` does that safely:
```bash
local -a selected_exclusions=()
if [[ -n "$raw_exclusions" ]]; then
    read -ra selected_exclusions <<< "$raw_exclusions"
fi
```
*(Note: the two other `eval`s — `validate.sh:311` restoring `shopt`, and
`wizard.sh:432` restoring a function definition — are intentional and correct.
Leave those.)*


---

## 7. Loosen the fstab presence check       *(Robustness)*

**`wizard.sh:345`** (`_ensure_backup_mounted`)
```bash
if ! grep -q "$BACKUP_UUID" /etc/fstab 2>/dev/null; then
```
A plain `grep -q` is a substring match, so a UUID appearing inside an unrelated
comment line would make the wizard skip adding a real mount entry. Anchor it to
a UUID token:
```bash
if ! grep -qE "(^|[[:space:]])${BACKUP_UUID}([[:space:]]|=|$)" /etc/fstab 2>/dev/null; then
```
Minor, but this is the one place the wizard edits `/etc/fstab` and correctness
matters.

---

## 8. Whole-disk regex misses multi-part names       *(Edge case)*

**`wizard.sh:314`** (`_format_backup_drive`)
```bash
if [[ "$dev" =~ ^/dev/[a-z]+$ ]] || [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
```
`^/dev/[a-z]+$` only matches pure-letter device names, so `mmcblk0`, `vd`, or
any name with digits/underscore is missed — those disks would skip partitioning
and fail later at `mkfs.btrfs`. A device that is *not* a partition is simply one
whose name is not `...pN`/`...N`. A more robust test:
```bash
if lsblk -no TYPE "$dev" 2>/dev/null | grep -qx disk; then
```
Low frequency, but it is the path that erases a drive, so it is worth hardening.

---

## 9. Cosmetic — inconsistent indentation in `parse_args`       *(Cosmetic)*

**`wizard.sh:30-80`** — the `case` labels and their arms are indented with an
inconsistent mix of spaces (some 5, some 3). Re-flow to a consistent 4-space
style. Purely cosmetic; bundle it with any other edit to `parse_args` so it
does not generate noise on its own.

---

## 10. Consistency — `set -euo pipefail` placement       *(Consistency)*

Each `lib/*.sh` file places `set -euo pipefail` *below* its header comment
(after a blank line, before the functions), rather than at the top. It works
because the files are sourced into the wizard shell (which already set it),
so the placement is cosmetic — but it is inconsistent with `wizard.sh` (top of
file) and reads oddly. Either move it under the shebang in every module, or drop
it entirely and rely on the parent shell. Pick one convention.

---

## 11. Observations — worth a thought, not a defect

- **`pika-cloud-sync.service` uses `rclone sync`** (`templates/pika-cloud-sync.service:10`).
   `sync` deletes remote objects not present locally — the intended behaviour for a
  mirror, but it is destructive. A one-line comment in the template noting "sync
  deletes stale remote files" would help the next reader. Design choice, not a bug.
- **`templates/os-clone-nag.sh:44`** composes `{{DETECTED_TERMINAL_CMD}} bash -c "..."`.
  For the `gnome-terminal --` candidate that becomes `gnome-terminal -- bash -c "..."`;
  verify it launches as intended, since `gnome-terminal` arg handling differs from
   `xterm -e`.
- **`--validate` without root + no dialog:** `ensure_dialog` (`packages.sh:149`)
  runs before the `--validate` branch in `main()`, so a rootless validate with no
   `dialog`/`whiptail` fatal-exits via `ensure_dialog` instead of reporting cleanly.
  Edge case only.
- **`run_as_user`** (`common.sh:188`) uses `sudo -u "$(get_real_user)"`. Fine in the
  interactive flow; just note it depends on `get_real_user` resolving, which relies on
   `SUDO_USER`/`logname`/`USER`.

---

## 12. Already good — do not "fix" these

Future reviewers: these are deliberate and correct.

- **`die()` contract** (`common.sh:100-115`) — `die()` is reserved for
  precondition failures in `wizard.sh`; layers return non-zero instead so the
  wizard always reaches runbook generation and validation. Well documented.
- **`layer_selected()`** (`common.sh:76`) — single authoritative definition,
  guarded against `set -u` with the `${arr[@]+"${arr[@]}"}` idiom. Good.
- **`SELECTED_LAYERS` pre-declaration** (`common.sh:71`) — prevents `set -u`
  trips before population. Correct.
- **`template_render`** (`common.sh:133`) — indirect `${!var:-}` expansion is
  safe under `set -u` for missing placeholders.
- **Idempotency** — `backup_file` before every write; nag-script sentinels
   (`BEGIN`/`END`) in `layer4_cloud.sh` + `uninstall.sh` with a fallback `sed`
  for older installs. Solid.
- **Dry-run isolation** (`wizard.sh:367-473`) — previews to
   `~/arch-backup-wizard-preview`, silences `ui_msgbox`, restores it. Nice.
- **`run_layer` non-fatal policy** (`wizard.sh:560`) — one layer failing never
  blocks the others. Correct for a multi-layer setup tool.
- **Resource throttling** (`Nice=19`, `IOSchedulingClass=idle`) — consistent
  across the btrbk override and the pika user timer. On theme for a gaming rig.
- **CI** (`.github/workflows/lint.yml`) runs `shellcheck -x` and ignores
   `templates/` — appropriate. Note: `shellcheck` is not installed locally, so
  the `make check` target cannot run on a bare box; worth documenting or
  packaging in the dev environment.

---

*Suggested order:* #1 (real bug) -> #6 (quality) -> #2-#5 (dead-code sweep) ->
the rest. All are independent and low-risk; each is a self-contained commit.

