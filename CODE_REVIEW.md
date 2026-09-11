# Code Review — Boy Scout Rule Findings

**Project:** Arch Backup Wizard (modular Bash TUI backup wizard for Arch Linux)
**Date:** 2026-09-10
**Scope:** All shell sources under `wizard.sh` and `lib/`, plus `templates/`.
**Method:** Static review against the *Boy Scout Rule* — leave the code slightly
cleaner than you found it. Findings are grouped by category and ordered by
impact. Each item cites concrete locations and a recommended fix.

No files were modified for this review; this document is analysis only.

---

## 0. Executive summary

The codebase is well-structured and clearly documented. A consistent
convention for `log_*`, `ui_*`, and `install_layer_packages`/`uninstall_*`
wrappers makes the intent readable. The issues below are **maintainability and
robustness** concerns rather than outright bugs, grouped so a maintainer can
clean up one area at a time.

Priority legend: **High** = can cause a real failure or silent wrong behaviour;
**Med** = consistency/DRY/readability; **Low** = polish.

| # | Finding | Priority |
|---|---------|----------|
| 1 | Inconsistent error-exit style: `die` vs `return 1` vs `ui_msgbox` + warn | High |
| 2 | Magic layer numbers (`"1".."5"`) scattered as strings | High |
| 3 | `layer_selected` re-defined identically in 3 places | High |
| 4 | `get_real_user`/`get_real_home` logic duplicated in 5+ call sites | Med |
| 5 | `set -euo pipefail` not applied in sourced library modules | High |
| 6 | `export -f setup_layer*` with no consuming subshell | Low |
| 7 | Magic numbers / hard-coded paths (preserve days, retention, paths) | Med |
| 8 | Inconsistent leading-space indentation on section comment lines | Low |
| 9 | `sleep 1` busy-wait before detection UI | Low |
| 10 | `detect.sh` uses unquoted globs / fixed-field `read` | Med |
| 11 | Validation "cross-layer" fstab check has a dead fallback branch | Low |
| 12 | No lint/CI (shellcheck, CI) despite `set -euo pipefail` intent | Med |
| 13 | Undeclared global variables used across module boundaries | Med |
| 14 | `--validate` parsing accepts any non-dash token | Med |
| 15 | `uninstall.sh` deletes whole user shell rc / omits user units | High |
| 16 | `--dry-run` success message is self-contradictory | Low |
| 17 | `README.md` minor doc gaps | Low |

---

## 1. Inconsistent error-exit style — **High**

### 1.1 Three different conventions for "fail a step"

Within `setup_layer1` (`lib/layer1_snapper.sh`) the same kind of failure is
handled three different ways:

- **`die`** for `install_layer_packages`, `umount`, `btrfs subvolume delete`,
   mounts, `systemctl enable` (lines 15, 28, 36, 41, 49, 74, 79, 86, 173, 187).
- **`return 1` + `ui_msgbox`** for the final verification step (lines 231–241).
- **`|| true` / `|| echo`** to swallow optional work (lines 78, 82, 163, 166).

`die` immediately exits the whole process, while `return 1` only returns from the
function. In `main()` the layers are invoked as:

```bash
layer_selected "1" && setup_layer1    # wizard.sh:552
```

Because `setup_layer1` mixes `die` and `return 1`, a failure inside step 5
(`grub`/`systemd-boot` enable) calls `die` and the wizard exits *without*
generating runbooks or running validation, whereas a verification failure in step
6 returns 1 and the wizard continues to the next layer silently. The
**contract of `setup_layerN` is therefore ambiguous**: does a non-zero return
mean "abort everything" or "skip to next layer"?

There is also a `set -e` subtlety: `layer_selected "3" && setup_layer3` is a
`&&` list, so if `setup_layer3` returns 1 the *last* command of the list fails
and — because it is not part of a condition — `set -e` may abort the whole
wizard. The intended "best-effort per-layer" behaviour is not expressed.

### Recommendation

Pick one contract and apply it:

1. Make every `setup_layerN` **return an exit code** and never call `die`
   internally. Replace `die "Failed to enable ..."` with `log_error ...; return 1`.
2. In `main()`, decide policy explicitly and avoid the `&&`/`set -e` trap:

```bash
run_layer() {
    local layer="$1"; shift
    if layer_selected "$layer"; then
        if ! "$@"; then
            log_error "Layer $layer setup failed; continuing to next layer"
            # or: die "Layer $layer setup failed"   # if abort-on-failure is desired
        fi
    fi
}
run_layer 1 setup_layer1
run_layer 2 setup_layer2
```

3. Keep `die` for **precondition / fatal** conditions in `wizard.sh` only
   (root check, BTRFS gate, no backup drive).


---

## 2. Magic layer numbers — **High**

Layer identity is carried as bare string literals `"1"`–`"5"` in many places:

- `wizard.sh:504` `SELECTED_LAYERS=("1" "2" "3" "4" "5")`
- `wizard.sh:552-556` `layer_selected "1" && setup_layer1` …
- `wizard.sh:375` iterates `SELECTED_LAYERS` and feeds `get_layer_packages "$l"`
- `packages.sh` `case "$1" in 1) … 2) … esac`
- `runbooks.sh` / `validate.sh` `layer_selected "2"` etc.
- `--validate` parse: `IFS=',' read -ra VALIDATE_LAYERS <<< "$1"` produces strings.

If a layer is ever renumbered (or 6 is added) every one of these must be updated
in lockstep, and a typo like `layer_selected "3 "` is not caught at parse time.

### Recommendation

Introduce named constants / a lookup, and stop passing raw numbers:

```bash
# lib/common.sh
readonly LAYER_SNAPPER=1 LAYER_BTRBK=2 LAYER_PIKA=3 LAYER_CLOUD=4 LAYER_DEEP=5

layer_name() {     # 1 -> "Snapper"
    case "$1" in
          1) echo "Snapper";; 2) echo "btrbk";; 3) echo "Pika Backup";;
          4) echo "Cloud Offsite";; 5) echo "Deep Storage";;
    esac
}
```

Then `main()` reads `layer_selected "$LAYER_SNAPPER" && setup_layer1`, and the
`--validate 1,2,3` path validates each token against the known set (it currently
accepts *anything* the user passes, including `--validate 99`).

---

## 3. `layer_selected` duplicated in three files — **High**

`layer_selected()` is defined **identically** in:

- `wizard.sh:162`
- `lib/runbooks.sh:9` (inside an `if ! declare -F` guard)
- `lib/validate.sh:10` (inside an `if ! declare -F` guard)

The guard `if ! declare -F layer_selected` is defensive but creates a *third copy
of the same logic*. If the matching semantics change, only the unguarded copy in
`wizard.sh` is the "real" one and the others silently diverge. This is the
canonical "leave it cleaner" candidate for extraction.

### Recommendation

Move the single definition to `lib/common.sh` (always sourced first) and delete
the two `if ! declare -F` blocks plus the in-`wizard.sh` copy. The standalone
`--validate` entry point already sources `common.sh` via `main`→`run_detection`,
so the guards are unnecessary.

```bash
# lib/common.sh
layer_selected() {
    local target="$1"
      [[ ${#SELECTED_LAYERS[@]} -eq 0 ]] && return 1
    local l
    for l in "${SELECTED_LAYERS[@]}"; do
          [[ "$l" == "$target" ]] && return 0
    done
    return 1
}
```

(Also note: the guard copies reference `SELECTED_LAYERS` but do not guard that the
array exists — calling `layer_selected` before `SELECTED_LAYERS=()` is declared in
`wizard.sh:137` would trip `set -u` in a context where that array is unset.
Declaring it in `common.sh` next to the function fixes both.)

---

## 4. Real-user / real-home resolution duplicated — **Medium**

`common.sh` already provides `get_real_user` (line 89) and `get_real_home`
(line 94). But the "real user" fallback is re-spelled-out in at least five
places, each with slightly different fallback logic:

- `layer3_pika.sh:24-26` `target_user="${DETECTED_USER:-$(get_real_user)}"`
- `layer4_cloud.sh:12` `local target_user="${DETECTED_USER:-$(get_real_user)}"`
- `layer5_deep_storage.sh:21` `local user="${DETECTED_USER:-$(get_real_user)}"`
- `runbooks.sh:48` `local target_user="${DETECTED_USER:-$(get_real_user)}"`
- `runbooks.sh:318` `target_user="${DETECTED_USER:-$(get_real_user)}"`
- `runbooks.sh:328` `target_home="${DETECTED_HOME:-$(get_real_home)}"`
- `uninstall.sh` / `validate.sh` use bare `${user_home}` / `${DETECTED_HOME}`
  without the `get_real_home` fallback.

The inconsistency (`DETECTED_USER` vs `DETECTED_HOME` vs `user_home` vs
`get_real_home`) is a maintenance hazard: a new layer author has to remember the
exact fallback idiom.

### Recommendation

Add two helpers to `common.sh` that centralise the fallback once:

```bash
effective_user() { echo "${DETECTED_USER:-$(get_real_user)}"; }
effective_home() { echo "${DETECTED_HOME:-$(get_real_home)}"; }
```

and replace every call site with `local target_user="$(effective_user)"`. This
also fixes `validate.sh`/`uninstall.sh`, which currently rely on a `user_home`
variable that is only set in the `--validate` branch of `main` — if
`run_validation` is ever called from a path where `user_home` is unset, the
`set -u` guard makes the check read empty.

---

## 5. `set -euo pipefail` not applied in sourced modules — **High**

`wizard.sh:8` sets `set -euo pipefail`. All `lib/*.sh` files are *sourced* into
the same shell, so the options **do** inherit at runtime. However:

- Each `lib/` module starts with `#!/usr/bin/env bash` but **no**
   `set -euo pipefail`. Anyone who sources a module in isolation (tests,
    `--validate` standalone helpers, a future `bash -c 'source lib/layer2_btrbk.sh'`)
   loses the strictness.
- Several `lib/` modules use `|| true` / `|| echo` to defeat `set -e`, which is
  correct, but a few places rely on the *absence* of strict mode. For example
    `layer2_btrbk.sh:75-79` runs `systemctl daemon-reload` and
    `systemctl enable --now btrbk.timer` with **no error handling** — under
    `set -e` these will abort the wizard on a transient failure; the intent
    (best-effort vs fatal) is unclear.

### Recommendation

Add `set -euo pipefail` to each `lib/*.sh` (defensive for isolation testing) and
make every `systemctl`/`mount`/`mkdir` call in the layer modules explicit about
`|| true` (best-effort) vs `|| die` / `|| { log_error; return 1; }` (fatal).
Audit list:

- `layer2_btrbk.sh:28` `mkdir -p /.snapshots_btrbk`
- `layer2_btrbk.sh:33` `mkdir -p "$backup_mount/OS_Backup"`
- `layer2_btrbk.sh:37` `mkdir -p /etc/btrbk`
- `layer2_btrbk.sh:60` `mkdir -p "$override_dir"`
- `layer2_btrbk.sh:75` `systemctl daemon-reload`
- `layer2_btrbk.sh:79` `systemctl enable --now btrbk.timer`

---

## 6. `export -f` on functions never used in a subshell — **Low**

`lib/layer{1..5}*.sh` each end with `export -f setup_layerN` (e.g.
`layer1_snapper.sh:246`, `layer3_pika.sh:187`). `run_as_user` uses
`sudo -u` which **does** start a new shell, but the exported functions are
`setup_layerN`, which are called from the *parent* shell (`wizard.sh:552`), not
from a `run_as_user` subshell. So the export is dead weight and misleading — it
implies these functions are meant to cross a `sudo` boundary, which they are not.
(`sudo` does not inherit exported Bash functions anyway, so even if intended it
would not work.)

### Recommendation

Remove the `export -f setup_layerN` lines. Keep `export -f` only for functions
that are genuinely passed to `run_as_user`.

---

## 7. Magic numbers / hard-coded retention and paths — **Medium**

Retention and schedule values are embedded as literals with no central place to
tune or validate them:

- `layer2_btrbk.sh:43-46` `snapshot_preserve_min 7d` / `snapshot_preserve 14d` /
    `target_preserve_min latest` / `target_preserve 14d`.
- `layer3_pika.sh:141-142` "Hourly: 12, Daily: 7, Weekly: 4, Monthly: 6"
   appears as a UI string only — Pika is configured by the user in the GUI, so the
   wizard never actually sets these. The instruction drifts from any default.
- `layer5_deep_storage.sh:123` `--prune 'keep_hourly=1,keep_daily=7,keep_weekly=4'`
   hard-coded Borg retention.
- Paths `/.snapshots`, `/.snapshots_btrbk`, `/etc/btrbk/btrbk.conf`,
    `/usr/local/bin/os-cloud-backup.sh`, `/usr/local/bin/rollback.sh`,
    `/usr/local/bin/run-recovery` are scattered.

### Recommendation

Introduce a small `lib/defaults.sh` (or add constants to `common.sh`):

```bash
readonly BTRBK_SNAP_MIN="7d"     BTRBK_SNAP="14d"
readonly BTRBK_TARGET_MIN="latest" BTRBK_TARGET="14d"
readonly BORG_PRUNE="keep_hourly=1,keep_daily=7,keep_weekly=4"
readonly SNAP_DIR_ROOT="/.snapshots"
readonly SNAP_DIR_BTRBK="/.snapshots_btrbk"
readonly RUNBOOK_DIR="/usr/local/bin"
```

and reference them in the heredocs (`snapshot_preserve_min ${BTRBK_SNAP_MIN}`).
Also: drop or implement the Pika pruning instruction in `layer3_pika.sh:141-142`
— either write the values into Pika's config, or remove the line so the UI does
not promise defaults the wizard cannot enforce.

---

## 8. Inconsistent leading-space indentation on section comments — **Low**

In several modules, "section" comment lines begin with a single leading space that
does **not** align with the surrounding code:

- `layer1_snapper.sh:171` ` # -- 4. Enable snapper-cleanup.timer ...`
- `layer1_snapper.sh:176` ` # Ensure timeline timer is disabled ...`
- `layer1_snapper.sh:182` ` # -- 5. Bootloader-specific setup ...`
- `layer1_snapper.sh:215` ` # -- 6. Verify ...`
- `layer4_cloud.sh:17,38`
- `layer5_deep_storage.sh:29`
- `validate.sh:104,152,218,233,257,281`

These look like leftover stray spaces from editing. `shfmt -i 4` would
normalize the whole tree.

### Recommendation

Either strip the leading space (preferred) or introduce `shfmt -i 4 -ci` in CI and
let it normalize the tree.

---

## 9. `sleep 1` busy-wait before detection UI — **Low**

`wizard.sh:518` `sleep 1` runs after `run_detection` and before
`show_detection_results`. The `ui_infobox "Scanning" ...` is shown *before*
detection, then a hard `sleep 1` paces the transition. On a fast machine the
"Scanning" box shows for ~1 s; on a slow one detection takes longer than 1 s and
the box disappears before detection finishes.

### Recommendation


Remove the `sleep 1` (the infobox already paces) or make the pacing a property of
the infobox itself.

---

## 10. `detect.sh` parses `findmnt`/`btrfs` output with unquoted word splitting — **Medium**

`detect.sh` extracts mountpoint/source/fs-type via:

```bash
for line in $(findmnt -no MOUNTPOINTS,SOURCE,FSTYPE,SIZE,UUID -r 2>/dev/null); do
  IFS=' ' read -r src fstype size uuid mpoints <<< "$line"
   ...
done
```

and similar at `detect_root_uuid`/`detect_btrfs_uuid`. Problems:

- `$(findmnt ...)` splits on **any** whitespace and runs glob expansion. A
   mountpoint or source containing a space or `*`/`?` breaks parsing or, worse,
   expands to a filename.
- `IFS=' ' read -r src fstype size uuid mpoints` silently truncates if
   `MOUNTPOINTS` contains a comma or an unexpected column count; `uuid` and
   `mpoints` then receive the wrong tokens.
- The `findmnt -o ... -r` column order is positional; if a field is absent for a
   mount, every subsequent column shifts.

### Recommendation

Prefer NUL-delimited output:

```bash
while IFS= read -r -d '' mp; do
  # parse per-field
done < <(findmnt -rn -o MOUNTPOINTS,SOURCE,FSTYPE,SIZE,UUID --target / 2>/dev/null)
```

or, if staying with `findmnt -r`, at minimum quote the command substitution
(`while IFS= read -r line; do … done < <(findmnt …)`) and read fields
explicitly from a known `--output` column set.

---

## 11. Dead `fstab_found` boolean in `validate.sh` — **Low**

`validate.sh:295-301`:

```bash
local fstab_line=$(grep -i "$backup_dev" /etc/fstab 2>/dev/null || true)
local fstab_found=false
if [[ -n "$fstab_line" ]]; then
    fstab_found=true
fi
if ! $fstab_found; then
    log_warn "Layer 5 requires /etc/fstab entry for $backup_dev"
fi
```

`fstab_found` is a redundant mirror of `-n "$fstab_line"`. The intermediate
boolean adds a write-and-read cycle with no added clarity.

### Recommendation

Collapse to:

```bash
if [[ -z "$(grep -i "$backup_dev" /etc/fstab 2>/dev/null || true)" ]]; then
    log_warn "Layer 5 requires /etc/fstab entry for $backup_dev"
fi
```

---

## 12. `--validate LAYERS` accepts invalid layer IDs silently — **Medium**

`wizard.sh:33-37`:

```bash
--validate)
    VALIDATE_LAYERS="${1:-1,2,3,4,5}"
    shift
   ;;
```

The value is later split on `,` and passed to `layer_selected`, which returns 1
for any token that is not `1..5`. An invalid token (`--validate 1,9,3`) is
silently dropped, and `run_validation` only validates the layers that *match*.
The user gets no feedback that `9` was ignored.

### Recommendation

Validate the token set before dispatching:

```bash
--validate)
    VALIDATE_LAYERS="${1:-1,2,3,4,5}"
    shift
    IFS=',' read -ra _layers <<< "$VALIDATE_LAYERS"
    for l in "${_layers[@]}"; do
        case "$l" in
            1|2|3|4|5) ;;
            *) die "Invalid layer id: '$l' (expected 1..5)" ;;
        esac
    done
   ;;
```

---

## 13. `uninstall.sh` deletes the user's entire `.bashrc`/`.zshrc` — **Critical**

`uninstall.sh:81-82`:

```bash
rm -f "$user_home/.zshrc"
rm -f "$user_home/.bashrc"
```

But `layer4_cloud.sh:193-200` only **appends** a small nag hook to the user's
existing rc file:

```bash
cat >> "$target_rc" << 'HOOK'
# arch-backup-wizard os-clone-nag
...
HOOK
```

Deleting the whole rc file when the wizard only appended a few lines will
**destroy any pre-existing shell configuration the user had before running the
wizard** — aliases, `PATH` additions, environment variables, plugin initialis-
ation, etc. This is the most severe finding in the codebase and a real data-loss
risk.

### Recommendation

Replace the two `rm -f` lines with a targeted block removal:

```bash
if grep -qF 'arch-backup-wizard os-clone-nag' "$user_home/.bashrc" 2>/dev/null; then
    sed -i '/# arch-backup-wizard os-clone-nag/,/^done$/d' \
        "$user_home/.bashrc" 2>/dev/null || true
fi
if grep -qF 'arch-backup-wizard os-clone-nag' "$user_home/.zshrc" 2>/dev/null; then
    sed -i '/# arch-backup-wizard os-clone-nag/,/^done$/d' \
        "$user_home/.zshrc" 2>/dev/null || true
fi
```

or, better, write the hook between a sentinel comment pair so the `sed` range
is unambiguous:

```bash
cat >> "$target_rc" << 'HOOK'
# arch-backup-wizard os-clone-nag BEGIN
...
done
# arch-backup-wizard os-clone-nag END
HOOK
```

---

## 14. `--dry-run` summary message is self-contradictory — **Low**

`wizard.sh:448-454`:

```bash
log_info "── DRY-RUN: NO RUNBOOKS GENERATED ──"
log_info "  (preview directory: $preview_dir)"
if [[ -d "$preview_dir" ]]; then
    rb_count=$(find "$preview_dir" -name 'rollback-*.txt' 2>/dev/null | wc -l)
    log_info "  $rb_count recovery runbooks generated in $preview_dir"
fi
```

The first line claims *no* runbooks are generated, then the next line reports a
count of runbooks that *were* written to the preview directory. In dry-run mode
the runbooks are generated but not copied to `/usr/local/bin`; the message
should say that explicitly.

### Recommendation

```bash
log_info "── DRY-RUN: runbooks written to preview dir only ──"
log_info "  preview: $preview_dir"
if [[ -d "$preview_dir" ]]; then
    rb_count=$(find "$preview_dir" -name 'rollback-*.txt' 2>/dev/null | wc -l)
    log_info "   $rb_count preview runbook(s) written"
fi
```

---

## 15. Missing CI / `shellcheck` / `shfmt` pipeline — **Medium**

The codebase has no CI workflow, no `Makefile` target, no `.shellcheckrc`, and
no formatting configuration. `shellcheck` is the standard static analyser for
Bash and would catch several of the above issues automatically:

- `local x="$(cmd)"` exit-status masking (finding 14) → `SC2155`
- `for x in $(cmd)` word-splitting (finding 10) → `SC2206`
- unquoted `$pkgs` in `pacman -S --needed $pkgs` → `SC2086`
- `IFS=' '` read → `SC2162`

### Recommendation

Add a `.github/workflows/lint.yml`:

```yaml
name: Lint
on: [push, pull_request]
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
       - uses: actions/checkout@v4
       - uses: lundeen/action-shellcheck@v1
```

and a `Makefile` for local convenience:

```makefile
check:
    shellcheck -x wizard.sh lib/*.sh
```

---

## 16. Undeclared globals used across modules — **Medium**

The following globals are set in `detect.sh` or `wizard.sh` and consumed in
`lib/*.sh`, but no module declares or documents its *input* contract:

- `DETECTED_USER` / `DETECTED_HOME` — consumed by `layer3`, `layer4`, `layer5`,
    `runbooks.sh`
- `DETECTED_BACKUP_MOUNT` / `DETECTED_BACKUP_UUID` — consumed by `layer2`,
    `layer4`, `layer5`, `runbooks.sh`
- `BACKUP_MOUNT` — set in `wizard.sh:507` as a normalised copy of
    `DETECTED_BACKUP_MOUNT`
- `RUNBOOK_DIR` — consumed by `runbooks.sh`
- `SELECTED_LAYERS` — consumed by `runbooks.sh`, `validate.sh`
- `WIZARD_HOME` — consumed by `ui.sh`

A new layer author must read every module to discover which globals are
pre-conditions. This is the root cause of findings 4 and 13 (undefined
`user_home` in `validate.sh`/`uninstall.sh`).

### Recommendation

Add a `lib/contract.sh` (or a header comment in `common.sh`) that documents each
global's producer, consumer, and default:

```bash
# ── Global contract ─────────────────────────────────────────────────────────
# DETECTED_USER         – set by detect.sh; consumer: layer3, layer4, layer5
#                        fallback: get_real_user()
# DETECTED_HOME         – set by detect.sh; consumer: layer3, layer4, layer5
#                        fallback: get_real_home()
# DETECTED_BACKUP_MOUNT – set by detect.sh; consumer: layer2, layer4, layer5
# RUNBOOK_DIR           – set by wizard.sh; consumer: runbooks.sh
# SELECTED_LAYERS       – set by wizard.sh; consumer: runbooks.sh, validate.sh
# ────────────────────────────────────────────────────────────────────────────
```


---

## 17. `README.md` missing operational detail — **Low**

The `README.md` covers installation and basic usage but omits:

- `--dry-run` flag behaviour (and the runbook preview directory)
- `--validate` flag and valid layer IDs
- Uninstall procedure
- The user `.bashrc`/`.zshrc` hook (finding 13) and how to remove it
- `DRY_RUN` and `DETECTED_*` environment variable contract

### Recommendation

Add an **Advanced Usage** section covering `--dry-run`, `--validate`, and
`--uninstall`, and a **Customisation** section that documents the `DETECTED_*`
environment variables.

---

## 18. Priority action list

| #  | Severity | Finding                         | Effort |
|----|----------|--------------------------------|--------|
| 13 | Critical | `uninstall.sh` destroys user rc | S      |
| 5  | High     | `set -euo pipefail` not in lib | S      |
| 3  | High     | Ambiguous `die` vs `return 1`  | M      |
| 10 | Medium   | `detect.sh` word-split parsing | M      |
| 7  | Medium   | Magic numbers / paths          | S      |
| 12 | Medium   | `--validate` accepts bad IDs   | S      |
| 15 | Medium   | No CI / shellcheck             | S      |
| 16 | Medium   | Undeclared global contract     | M      |
| 6  | Low      | Dead `export -f`               | S      |
| 8  | Low      | Inconsistent comment indent    | S      |
| 9  | Low      | `sleep 1` busy-wait            | S      |
| 11 | Low      | Dead `fstab_found` boolean     | S      |
| 14 | Low      | Contradictory dry-run message  | S      |
| 17 | Low      | README missing advanced usage  | S      |

*S = small (≤ 30 min), M = medium (30 min – 2 h)*

---

## Appendix A — File map

| File                          | Responsibility                             |
|-------------------------------|-------------------------------------------|
| `wizard.sh`                   | Entry point; argument parsing; main flow  |
| `lib/common.sh`               | Logging, `die`, `run_as_user`, `ensure_root` |
| `lib/ui.sh`                   | `dialog`/`whiptail` wrappers              |
| `lib/packages.sh`             | `install_layer_packages`, `get_layer_packages` |
| `lib/detect.sh`               | System detection → `DETECTED_*` globals   |
| `lib/layer1_snapper.sh`       | Snapper setup; `setup_layer1`             |
| `lib/layer2_btrbk.sh`         | btrbk setup; `setup_layer2`               |
| `lib/layer3_pika.sh`          | Pika GUI setup; `setup_layer3`            |
| `lib/layer4_cloud.sh`         | rclone cloud setup; `setup_layer4`        |
| `lib/layer5_deep_storage.sh`  | Borg deep storage; `setup_layer5`         |
| `lib/runbooks.sh`             | Runbook generation; `generate_runbooks`   |
| `lib/validate.sh`             | Layer validation; `run_validation`        |
| `lib/uninstall.sh`            | Uninstall; `run_uninstall`                |
| `templates/*.tmpl`            | Jinja-style runbook templates             |

---

## Appendix B — Cross-cutting naming convention

| Prefix / name       | Scope                         |
|---------------------|-------------------------------|
| `DETECTED_*`        | Set by `detect.sh`, read-only |
| `SELECTED_LAYERS`   | Set by `wizard.sh`, read-only |
| `WIZARD_HOME`       | Set by `wizard.sh`, read-only |
| `RUNBOOK_DIR`       | Set by `wizard.sh`, read-only |
| `BACKUP_MOUNT`      | Set by `wizard.sh`, read-only |
| `DIALOG_CMD`        | Set by `ui.sh`, read-only     |
| `DRY_RUN`           | Set by `wizard.sh`, read-only |
| `VALIDATE_LAYERS`   | Set by `wizard.sh`, read-only |
| `setup_layerN`      | Exported function per layer   |
| `run_<verb>`        | Top-level workflow functions  |
| `generate_*`        | Content generators            |


