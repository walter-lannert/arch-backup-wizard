# Code Review — Arch Backup Wizard

**Review date:** 2026-09-25

**Reviewed range:** `00fedecac68d87e001f946e8c1f78358e1ddce24^..a44e95f5422072dda6e90c182bd17e4f4dce5b28` (the requested commit, inclusive, through current `HEAD`)

**Scope:** the complete repository, with detailed review of the 15 non-merge commits (27 commits including merges) in the requested range and adjacent producer/consumer code needed to verify their contracts.

**Priority order:** correctness, performance, code quality.

**Method:** Boy Scout Rule — follow each changed path through setup, scheduled execution, validation, recovery, and uninstall, and recommend the smallest changes that leave those workflows safer and easier to verify.

## Executive summary

The reviewed commits fix several serious defects from the previous audit: snapshot naming is now shared, missing template variables are rejected, rclone destinations are propagated, cloud jobs have bounded timeouts and retention, and CI runs lint plus tests. Those improvements are worth keeping.

The current revision is still not ready to be described as a production-safe backup and recovery tool. The uninstaller can replace `/etc/fstab` with an old pre-install copy, discarding unrelated changes made after installation; if the expected backup file is absent, it can leave `/etc/fstab` deleted. Other high-impact gaps affect validation, dependency handling, recovery across encryption-mode changes, missing subvolume data, monitoring of failed Pika cloud syncs, and destructive handling of an existing Snapper subvolume.

**Release recommendation:** block release until CR-001 through CR-005 and CR-012 through CR-014 are fixed and exercised in a disposable Arch VM. CR-001 and CR-013 deserve destructive-path regression tests before anyone runs uninstall or Layer 1 setup on a real system.

## Finding index

| ID | Severity | Priority | Area | Finding |
|---|---|---|---|---|
| CR-001 | **Critical** | Correctness | Uninstall | Uninstall can overwrite or delete `/etc/fstab` |
| CR-002 | **High** | Correctness | Validation | Persisted settings override an explicit `--validate` layer subset and current detection |
| CR-003 | **High** | Correctness | Layer dependencies | Layer 4 is configured after failed Layer 2/3 setup, and an uninitialized Pika repository is reported as configured |
| CR-004 | **High** | Correctness | Cloud recovery | Recovery chooses decryption from current settings instead of the selected archive's format |
| CR-005 | **High** | Correctness | Health monitoring | Validation can report Pika cloud sync healthy when every scheduled service run is failing |
| CR-006 | **Medium** | Correctness | Generated runbook | The Layer 2 + Layer 4 runbook always includes a Pika restore workflow, even when Layer 3 was not configured |
| CR-007 | **Medium** | Correctness | Paths/systemd | Accepted backup paths containing spaces render broken systemd mount dependencies |
| CR-008 | **Medium** | Performance | Pika sync | The weekly timer performs two full sync scans because its documented idempotency guard does not exist |
| CR-009 | **Low** | Performance | OS cloud backup | The same remote directory is listed once per subvolume during retention pruning |
| CR-010 | **Medium** | Code quality | Tests/CI | Critical setup, rendered-unit, migration, and uninstall contracts have no automated coverage |
| CR-011 | **Low** | Code quality | Repository hygiene | The reviewed range fails `git diff --check` and documentation is already out of sync |
| CR-012 | **High** | Correctness | Disaster recovery | Recovery silently creates empty subvolumes for any missing non-root snapshot |
| CR-013 | **Critical** | Correctness | Layer 1 setup | Setup recursively deletes an existing `/.snapshots` Btrfs subvolume without proving it is disposable wizard state |
| CR-014 | **High** | Correctness | Backup-drive setup | Reusing a backup drive can report success after unchecked filesystem and `/etc/fstab` mutations fail |

## Detailed findings

### CR-001 — Uninstall can overwrite or delete `/etc/fstab` (**Critical**)

**Locations:** `lib/layer1_snapper.sh:115-130`, `lib/uninstall.sh:63-68`, `lib/uninstall.sh:77-118`

When Layer 1 adds the managed `/.snapshots` entry, it records the whole `/etc/fstab` path in the generic manifest. Uninstall first removes the wizard's tagged blocks surgically, which is appropriate. It then reads the manifest and treats `/etc/fstab` like an ordinary generated file:

1. `rm -f "$file"` removes the current `/etc/fstab`.
2. The oldest `${file}.bak.*` is moved into place when available.
3. If no matching backup remains, no restoration branch runs and the file stays absent.

Even in the normal case, restoring the oldest pre-wizard copy discards any legitimate mounts or edits added after the wizard was installed. That contradicts the documented safe/idempotent uninstall behavior and can make the next boot fail or mount the wrong filesystems.

**Required fix:** never put shared files such as `/etc/fstab` in the deletion manifest. Track only the owned BEGIN/END block and remove that block atomically from the current file. Add an explicit denylist in the generic removal loop for shared system/user files so a future caller cannot repeat the mistake. Before replacement, validate with `findmnt --verify`, preserve mode/owner, and leave the current file untouched on failure.

**Required test:** create a fixture containing pre-wizard lines, both managed blocks, and a post-install user line. Uninstall must remove only the managed blocks and preserve every other byte. A second test should run without any `.bak` files and prove `/etc/fstab` is never removed.

### CR-002 — Persisted settings override an explicit `--validate` layer subset and current detection (**High**)

**Locations:** `wizard.sh:755-767`, `lib/validate.sh:10-13`, `lib/common.sh:154-159`

The CLI correctly assigns `SELECTED_LAYERS` from `--validate 1,3,4` and assigns the currently detected backup mount immediately before calling `run_validation`. The first action inside `run_validation`, however, is `load_settings`, which sources assignments for `SELECTED_LAYERS`, `BACKUP_MOUNT`, `BACKUP_UUID`, and other values from the previous setup.

Consequences:

- `./wizard.sh --validate 5` can validate the previously selected layers instead of Layer 5.
- a stale saved backup mount can replace the mount found by the current detection pass;
- the dashboard and exit status no longer correspond to the command the operator ran.

The existing validation tests do not expose this because their settings files normally omit `SELECTED_LAYERS` and `BACKUP_MOUNT`.

**Required fix:** load persisted settings before applying CLI/detection overrides, not inside the validation function. Alternatively, make `load_settings` populate only unset variables and pass the requested layer set explicitly to `run_validation`. Add a regression test whose settings file selects `1,2,3` while the caller requests only `5`.

### CR-003 — Layer 4 is configured after failed Layer 2/3 setup (**High**)

**Locations:** `wizard.sh:813-840`, `lib/layer3_pika.sh:198-241`, `lib/layer4_cloud.sh:31-55`, `lib/layer4_cloud.sh:229-271`, `lib/layer4_cloud.sh:362-407`

The new `CONFIGURED_LAYERS` tracking is used for runbook generation, but Layer 4 still decides what to install from `layer_selected`. Therefore:

- if Layer 2 fails, Layer 4 can still generate an OS upload script for snapshots that are not being produced;
- if Layer 3 fails, Layer 4 can still install and enable a Pika cloud service for a repository that is absent;
- Layer 3 itself returns success after detecting that the Borg repository is uninitialized, so it is added to `CONFIGURED_LAYERS` despite the warning and despite comments saying it is not configured.

The post-setup validator may later flag some symptoms, but by then the wizard has already written and enabled dependent jobs and displayed Layer 4's success message.

**Required fix:** make Layer 3 return non-zero until the repository markers and acceptable Borg result are present. Before each Layer 4 branch, require the corresponding prerequisite with `layer_configured`, not `layer_selected`; Layer 4 may proceed with the other independently configured source. Add fault-injection tests for failed Layer 2, uninitialized Layer 3, and one-good/one-bad mixed selection.

### CR-004 — Cloud recovery uses current encryption state instead of archive format (**High**)

**Locations:** `lib/runbooks.sh:118-142`, `templates/os-cloud-backup.sh:76-83`

The uploader intentionally retains both `.btrfs.zst` and `.btrfs.zst.age` names, which allows a user to change the optional Age setting on a later wizard run. The generated recovery script also lists both formats, but it builds one fixed pipeline from the current `LAYER4_ENCRYPT` value:

- current setting `true`: every selected archive is passed through `age -d`;
- current setting `false`: every selected archive goes directly to `zstdcat`.

Immediately after changing the setting—and until a new backup of every subvolume completes—the newest available archive may use the opposite format. A disaster during that interval yields a runbook that cannot restore the backups that actually exist. Partial uploads make the mismatch possible per subvolume as well.

**Required fix:** select the pipeline from each `$ARCHIVE` suffix at recovery time: decrypt only `*.age`, and reject unknown extensions. Keep the private-key step conditional on whether any selected archive is encrypted. Add mixed-history tests covering encrypted-only, unencrypted-only, and a mix across subvolumes.

### CR-005 — Validation can report Pika cloud sync healthy while scheduled runs fail (**High**)

**Locations:** `lib/validate.sh:328-345`, `lib/layer4_cloud.sh:358-407`, `templates/pika-cloud-sync.service:15-34`, `templates/pika-cloud-sync-stale-check.service:1-12`, `templates/pika-cloud-sync-stale-check.timer:1-11`

For the Pika branch, Layer 4 validation checks only that the main service/timer files exist and that the timer is enabled and active. A systemd timer remains active when its triggered service fails, so bad credentials, a missing remote directory, snapshot failures, and repeated `rclone` failures can all still produce `Layer 4 ... OK`.

The repository contains stale-check service/timer templates, but setup never renders, installs, enables, validates, or uninstalls them. As a result, `/var/lib/pika-cloud-sync/state` can remain old indefinitely with no health failure or alert. This is especially serious for a Pika-only Layer 4 setup because no OS backup script exists to provide the separate rclone connectivity check.

**Required fix:** validate the last `pika-cloud-sync.service` result and a bounded-age success marker, and test the configured Pika destination as the target user. Either fully manage the stale-check units or remove the dead templates and replace them with an explicit check in validation. Add tests for a timer that is active while the service's last result is failed.

### CR-006 — The Layer 2 + Layer 4 runbook always includes a Pika restore workflow (**Medium**)

**Locations:** `lib/runbooks.sh:250-283`, `templates/cloud-recovery-runbook.txt:401-483`, `lib/layer4_cloud.sh:246-263`

A cloud recovery runbook is generated when Layer 2 and Layer 4 are configured; Layer 3 is not part of the condition. The template nevertheless always instructs the operator to mount and restore a cloud Borg repository. On a valid OS-only selection (`2,4`), `CLOUD_PIKA_DIR` can be empty, a default that was never configured, or a stale value loaded from an older run.

In a disaster this sends the operator into a failing or unrelated recovery step and undermines confidence in the rest of the runbook.

**Required fix:** render the Pika section only when Layers 3 and 4 are configured and `CLOUD_PIKA_DIR` is non-empty. For home-only cloud setups, provide a focused Pika recovery runbook rather than requiring Layer 2.

### CR-007 — Accepted backup paths containing spaces break systemd dependencies (**Medium**)

**Locations:** `wizard.sh:431-483`, `wizard.sh:489`, `lib/layer2_btrbk.sh:242-251`, `lib/layer4_cloud.sh:365-368`, `templates/pika-cloud-sync.service:1-6`

Mount-point validation permits spaces and the wizard computes `SYSTEMD_BACKUP_MOUNT` with `\x20` escaping. Neither generated unit uses that escaped value:

- the btrbk override emits `RequiresMountsFor=$backup_mount`;
- the Pika unit emits `RequiresMountsFor={{BACKUP_MOUNT}}`.

systemd parses whitespace-separated paths in `RequiresMountsFor`, so a mount such as `/mnt/Backup Drive` becomes multiple invalid/wrong dependencies. Interactive setup accepts this path, fstab correctly escapes it, and later scheduled jobs can fail or start without the intended mount ordering.

**Required fix:** use one systemd-escaped mount variable consistently in every unit, or reject whitespace at input. Validate rendered units with `systemd-analyze verify` in Linux CI and add a mount-with-spaces fixture.

### CR-008 — The Pika timer performs two weekly full sync scans (**Medium**, performance)

**Locations:** `templates/pika-cloud-sync.timer:17-31`, `templates/pika-cloud-sync.service:21-27`

The timer fires Monday at both 00:00 and 06:00 UTC. Its comment says the second run is an idempotent safety retry because the service checks its last-success marker. The service contains no such guard; it always snapshots the backup volume and runs `rclone sync --checksum`.

After a successful first run, the second schedule repeats a complete local/remote checksum scan a few hours later. Large Borg repositories can contain many chunk files, so the redundant pass consumes disk I/O, cloud API calls, CPU, and network metadata operations even when no data changed.

**Required fix:** add a start guard that exits successfully when the state timestamp is already from the current weekly window, or use one calendar trigger and let systemd retry failures explicitly. Ensure the success marker is written only after a verified sync.

### CR-009 — Retention lists the same remote directory once per subvolume (**Low**, performance)

**Locations:** `templates/os-cloud-backup.sh:28-84`, especially `templates/os-cloud-backup.sh:78`

Each subvolume upload calls `rclone lsf` for the same cloud directory, then filters the complete result for that subvolume. A typical multi-subvolume layout therefore performs the same remote listing six or seven times per backup. Cloud remotes can make directory listing latency and API quotas significant.

**Suggested fix:** fetch the listing once before the loop, update the in-memory list after a successful upload/delete, and filter it per prefix. Keep pruning after verified upload so performance work does not weaken retention safety.

### CR-010 — Critical contracts have no automated coverage (**Medium**, code quality)

**Locations:** `tests/`, `.github/workflows/lint.yml`, `Makefile`

CI now correctly runs `make all`, and ShellCheck covers executable templates. However, the 37 tests still do not execute the most failure-prone workflows:

- no test calls `setup_layer2`, `setup_layer3`, `setup_layer4`, or `run_uninstall`;
- no test renders and semantically verifies the Pika systemd units;
- no test covers configured-vs-selected dependency failures;
- no test covers settings precedence for `--validate`;
- no test covers encryption-mode migration or mixed archive suffixes;
- the new distro-specific tests hard-code detected distro/bootloader values and only assert runbook text, so they do not test distro detection or installation integration.

This is why the functional defects above coexist with a green Linux CI design.

**Required fix:** add contract-level tests around generated artifacts and state transitions, then run destructive-path integration tests only in a disposable Arch VM/container with synthetic mounts. Test names should distinguish runbook rendering fixtures from true distro integration tests.

### CR-011 — Repository hygiene and documentation drift (**Low**, code quality)

**Locations:** `README.md:24-28`, `README.md:228-237`, `INTERFACE_MAP.md:39-82`, new distro test files

`git diff --check` reports trailing whitespace in the README and new CachyOS/EndeavourOS tests. The README still says there are 27 tests although there are 37. `INTERFACE_MAP.md` documents nonexistent helpers such as `track_file` and `substitute_template`, an outdated manifest name, and stale-check units that are not installed.

**Suggested fix:** make `git diff --check` a CI step, update generated/manual counts, and either maintain `INTERFACE_MAP.md` as part of interface-changing commits or replace duplicated details with links to the authoritative code.

### CR-012 — Recovery silently creates empty subvolumes for any missing non-root snapshot (**High**)

**Locations:** `lib/runbooks.sh:102-110`, `lib/runbooks.sh:149-156`

The generated bare-metal and cloud restore scripts fail when the root archive is missing, but for every other detected subvolume they print a warning and create an empty subvolume. The detector includes mounted data-bearing subvolumes such as `@home`, `@var`, and `@srv`; none are marked optional. If one archive is missing, mistitled, or fails to match while the root archive exists, the operator receives a successful script completion with that subvolume's data absent. The post-restore checks focus on root contents and do not detect an empty restored `@home`.

**Required fix:** preserve an explicit required/optional classification, default data-bearing detected subvolumes to required, and stop recovery on a missing required archive. Only create empty subvolumes when the operator explicitly marks them optional. Add a test with a valid root archive and missing `@home` archive that must fail before printing success.

### CR-013 — Layer 1 recursively deletes an existing Snapper subvolume without ownership proof (**Critical**)

**Locations:** `lib/layer1_snapper.sh:31-61`, especially `lib/layer1_snapper.sh:45-50`

When no `/etc/snapper/configs/root` exists, setup unmounts `/.snapshots` and then treats any Btrfs subvolume at that path as disposable: `btrfs subvolume delete -R "$SNAP_DIR"`. The recursive form removes nested subvolumes as well. There is no manifest/ownership check, snapshot inventory, backup, confirmation explaining that existing snapshots will be destroyed, or recovery path.

`/.snapshots` can be an administrator-created snapshot store, an orphaned configuration after a prior Snapper cleanup, or a mount layout that does not use the later-detected top-level `@snapshots`/`@.snapshots` convention. The absence of one Snapper config file does not establish ownership of its data. In that case, selecting Layer 1 can permanently destroy existing rollback snapshots before the new configuration has even been created.

**Required fix:** never recursively delete a pre-existing subvolume automatically. First identify a compatible existing Snapper layout and adopt it without deletion; otherwise stop and require an explicit, separately worded destructive confirmation after showing the subvolume and nested-snapshot inventory. Prefer moving only wizard-created state tracked in a manifest. Add a regression fixture with an unowned `/.snapshots` subvolume containing nested snapshots and assert setup leaves it intact.

### CR-014 — Reused backup drives can mask failed setup mutations (**High**)

**Locations:** `wizard.sh:245-263`, `wizard.sh:539-595`, `lib/common.sh:165-196`

The existing-drive path invokes `_ensure_backup_mounted || return 1`. In Bash, commands inside a function called as part of an `||` list are exempt from `set -e`; the function must therefore check every fallible operation itself. It does not check `mkdir`, `awk` while creating the cleaned `/etc/fstab`, `cp /etc/fstab`, either `mv -T` replacement, `chmod`, or the standard backup-directory `mkdir` calls. It ends with `log_info`, which returns zero, so a failed unchecked command can be followed by a successful return and “Backup mount ready” log.

This is especially dangerous around `/etc/fstab`: `backup_file` itself does not propagate a failed `cp -p`, and a failed copy/replace can leave the current configuration unmodified, incomplete, or unbacked while the wizard continues to enable jobs that assume the mount and directory tree are ready.

**Required fix:** make `_ensure_backup_mounted` explicitly check and propagate every mutation, using a temporary file plus `findmnt --verify` before a checked atomic replacement. Make `backup_file` fail when its copy fails. Avoid calling a complex mutating function in an `&&`/`||` context, or retain its strict error semantics deliberately. Add fault-injection tests for unwritable mount paths, failed backup copies, failed temporary-file creation, and failed `/etc/fstab` replacement; each must return non-zero without reporting the drive configured.

## Recommended remediation order

1. Make `/etc/fstab` uninstall block-only and add a destructive-path regression test (CR-001).
2. Establish state precedence: saved defaults, then current detection, then explicit CLI overrides (CR-002).
3. Make layer success truthful and gate Layer 4 branches on successfully configured prerequisites (CR-003).
4. Make cloud recovery select decryption by archive suffix and test mixed histories (CR-004).
5. Make Pika cloud health observable from last service result, destination access, and success age (CR-005).
6. Correct conditional runbook content and systemd path escaping (CR-006, CR-007).
7. Remove redundant cloud scans and put all cross-module contracts into CI (CR-008 through CR-011).
8. Fail closed when a data-bearing non-root subvolume is missing during recovery (CR-012).
9. Protect existing Snapper state and make backup-drive setup fail closed on every mutation (CR-013, CR-014).

## Positive observations worth preserving

- `subvolume_to_snapshot_name` now gives btrbk, upload, and recovery code one naming contract, with backward-compatible lookup.
- Recovery fails closed when the required root snapshot/archive is missing.
- Template rendering rejects unset placeholders rather than silently producing empty critical commands.
- Optional Age encryption is recorded in persistent settings, and the key-escrow warning is appropriately prominent.
- Cloud upload now verifies remote size before local cleanup and applies bounded retention.
- The Pika service has finite systemd/rclone timeouts and cleanup hooks for both success and failure.
- Layer setup continues after an isolated failure while recording configured layers for later runbook decisions; CR-003 is about completing that design, not discarding it.
- CI now runs both ShellCheck and the shell test suite.

## Verification performed

- `make check` — passed with the locally installed ShellCheck.
- `make all` — lint passed; tests stopped at `tests/test_cachyos.sh` because the development host provides Bash 3.2, which cannot parse the Bash 4.2+ `[[ -v ... ]]` used by `lib/common.sh`. The project documents Arch Linux as its runtime target, so this is recorded as an environment limitation rather than a production defect.
- `git diff --check 00fedec^..HEAD` — failed on trailing whitespace in `README.md`, `tests/test_cachyos.sh`, and `tests/test_endeavouros.sh`.
- Static producer/consumer tracing of settings precedence, configured-layer state, btrbk snapshot names, archive suffixes, rclone destinations, Pika repository paths, systemd schedules/state, recovery runbooks, manifests, and uninstall restoration.
- Read-only inspection only: no partitions, mounts, packages, system services, cloud remotes, or backup data were modified.

`systemd-analyze verify` and end-to-end backup/restore testing were not available on this non-systemd macOS host. Final release validation still requires a disposable Arch VM with source/backup BTRFS filesystems and a test rclone remote.
