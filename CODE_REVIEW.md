# Repository Code Review

Reviewed: 2026-10-01

Branch: `bgra_review`

Revision: `7a311e5c8a37ccfb1d7f145f0ac25d33f60815e0`

Scope: application scripts, libraries, templates, tests, CI, VM tooling, and repository documentation. Recent changes were also compared with `29689a2` to distinguish regressions from existing debt.

## Executive assessment

**The repository is not yet demonstrably high-quality or safe enough to entrust with unattended backup and disaster recovery.** Its modular layout, defensive checks, naming helper, logging, and ShellCheck gate are good foundations. However, destructive operations do not consistently prove ownership or emptiness; recovery instructions contain independent execution blockers; and several checks confuse configuration presence with successful, recoverable backups.

The most important Boyscout Rule violation is that recent fixes sometimes replace a defect with a partial safeguard without testing the underlying contract. Examples include checking for nested subvolumes instead of checking for user data, interpreting any Borg fatal error as an encryption prompt, and adopting whole shared files based on a comment signature. These are correctness problems, not cosmetic preferences.

Do not treat the current successful lint result, an enabled timer, or a generated runbook as evidence that a restore will succeed. Address the destructive paths first, then exercise recovery on disposable CachyOS/Limine systems before claiming production readiness.

Only this review document was written. No application code, configuration, tests, or Git history were changed during the review.

## Verification and limitations

| Check | Result | Interpretation |
| --- | --- | --- |
| `make check` | Passed | ShellCheck 0.11.0 accepted the files included by the Makefile; the working-tree whitespace check passed. |
| `make test` | Blocked before test execution | Host Bash 3.2.57 cannot parse `[[ -v ... ]]` in `lib/common.sh:151`. This is a host/runtime mismatch, not proof of a syntax error on supported CachyOS. |
| Supplemental ShellCheck over `vm-test-cachyos/*.sh` and `vm-test-cachyos/cidata/*.sh` | Failed | VM tooling is outside the normal lint gate; findings include SC2319 status-capture warnings and SC2012. These warnings alone do not establish a runtime failure. |
| Safe function-level probes | Confirmed selected defects | Original functions were loaded unchanged, with system tools replaced by harmless mocks and temporary fixtures outside the repository. No real subvolume was deleted. |
| Linux integration, rendered systemd execution, and boot recovery | Not performed | This host is macOS, and the Docker daemon was unavailable. No VM, packages, services, mounts, disks, or cloud objects were modified. |

The probes confirmed: deletion attempted for a nonempty subvolume without nested subvolumes; the destructive-dialog arity crash; execution continuing after TERM; a shared `.bashrc` entering the deletion manifest; empty configured-layer state accepting an unconfigured prerequisite; retention of `subvolid=256` in generated rollback mount options; and prefix sorting selecting an older hashed snapshot over a newer legacy snapshot.

There are 41 declared test functions in the current unit-test files. This review does **not** claim that they passed. No target-runtime syntax error was established by the lint gate; the confirmed runtime and generated-command defects below are more significant than superficial syntax cleanup.

Evidence labels used below:

- **Confirmed:** directly evident in production code, supported by a safe probe or an explicit upstream command contract where relevant.
- **Inferred risk:** an architectural failure mode deduced from the implementation, not an observed production incident.
- **Open point:** a missing guarantee or test that must be resolved before making the associated quality claim.

## Prioritized open points and improvements

Priority definitions: **P0** = destructive-path release blocker; **P1** = recovery, integrity, security, or false-success defect to fix before production reliance; **P2** = operational reliability or coverage improvement; **P3** = maintainability and documentation cleanup. Ordering within a priority reflects expected harm and breadth, not implementation convenience.

| Rank / ID | Priority | Actionable finding |
| --- | --- | --- |
| 01 / R01 | P0 | Prevent uninstall from deleting nonempty Btrfs subvolumes. |
| 02 / R02 | P0 | Preserve preexisting Snapper data and repair the destructive confirmation call. |
| 03 / R03 | P1 | Replace signature-based whole-file adoption with explicit resource ownership. |
| 04 / R04 | P1 | Restrict archive cleanup to tracked temporary files. |
| 05 / R05 | P1 | Remove or remap stale subvolume IDs throughout recovery. |
| 06 / R06 | P1 | Preserve snapshot-layout metadata and reconstruct required subvolumes. |
| 07 / R07 | P1 | Run the cloud recovery filesystem check on an unmounted target. |
| 08 / R08 | P1 | Fix cloud recovery kernel metadata and archive selection. |
| 09 / R09 | P1 | Make Borg recovery compatible with read-only storage. |
| 10 / R10 | P1 | Escape systemd date specifiers in both cloud units. |
| 11 / R11 | P1 | Model selected, attempted, failed, and configured layers separately. |
| 12 / R12 | P1 | Reject incomplete or stale OS uploads instead of stamping success. |
| 13 / R13 | P1 | Stop interpreting every Borg exit code 2 as a valid encrypted repository. |
| 14 / R14 | P1 | Validate completed backups and missing/corrupt freshness state. |
| 15 / R15 | P1 | Actually reload persisted retention settings before applying defaults. |
| 16 / R16 | P1 | Propagate template and configuration write failures explicitly. |
| 17 / R17 | P1 | Check physical disk ancestry, not only filesystem device IDs. |
| 18 / R18 | P1 | Make fstab changes a single validated transaction. |
| 19 / R19 | P1 | Make uninstall ownership-aware, complete, and retryable. |
| 20 / R20 | P1 | Preserve a known-good cloud Borg generation during synchronization. |
| 21 / R21 | P1 | Render values according to their actual shell/systemd/config context. |
| 22 / R22 | P1 | Replace misleading integration coverage with executed production contracts. |
| 23 / R23 | P2 | Select and retain snapshots by timestamp and generation, not full-name order. |
| 24 / R24 | P2 | Terminate the uploader after signals and clean up child processes. |
| 25 / R25 | P2 | Make CLI validation genuinely independent of dialog. |
| 26 / R26 | P2 | Generate recovery instructions for Pika-only cloud configurations. |
| 27 / R27 | P2 | Enforce supported platform/shell boundaries instead of silently falling back. |
| 28 / R28 | P2 | Make persisted settings atomic, validated, and schema-driven. |
| 29 / R29 | P3 | Correct stale interface and operational documentation. |
| 30 / R30 | P3 | Reduce duplicated recovery logic, global coupling, and lifecycle hacks. |
| 31 / R31 | P3 | Expand the lint/CI contract and document the development runtime. |

## Detailed findings

### R01 — P0: Uninstall's emptiness safeguard can delete user data

**Evidence:** `lib/uninstall.sh:86–105`. **Confirmed.**

The condition uses `btrfs subvolume list -o "$file" | grep -q .` to decide whether deletion is safe. That lists nested subvolumes, not ordinary files. A subvolume containing documents but no child subvolume passes the test and is deleted. A listing failure is also indistinguishable from an empty result. The comment claiming that only empty subvolumes are removed is incorrect. The harmless uninstall probe reproduced the deletion attempt against a fixture containing a payload file. Btrfs deletion is an operation on the subvolume and its contents, not an `rmdir`-style empty-directory safeguard. See the [Btrfs subvolume command documentation](https://btrfs.readthedocs.io/en/latest/btrfs-subvolume.html).

**Improve:** require recorded ownership, inspect ordinary contents and nested subvolumes separately, and refuse deletion when inventory fails. Preserve nonempty resources by default; deleting backup data needs a separate, explicit request. Inspect before invoking related destructive Snapper cleanup too.

**Acceptance:** exercise the actual uninstall function with empty, ordinary-file, nested-subvolume, unowned, and unreadable targets. Only a proven empty, wizard-owned target is automatically deleted.

### R02 — P0: Snapper setup destroys preexisting resources and its confirmation can crash

**Evidence:** `lib/layer1_snapper.sh:31–56`; `lib/ui.sh:163–167`. **Confirmed.**

Setup unmounts an existing snapshot mount, then recursively deletes a preexisting snapshot subvolume. The confirmation is conditional on nested subvolumes, so ordinary contents receive no equivalent protection. A failed nested-subvolume listing can fall through to deletion. In the nested case, `ui_confirm_destructive "Nested snapshots detected"` omits the mandatory second argument; under `set -u`, the UI function exits with `$2: unbound variable`. The safe probe reproduced this exit. Disabling `errexit` in the layer runner does not disable `nounset`.

**Improve:** adopt or migrate existing Snapper layouts without deleting their contents. Establish ownership and obtain a fully described confirmation before any unmount or destructive action. Treat failed inventory as an error; do not use lazy unmount as a routine migration shortcut. Pass both UI arguments and validate wrapper arity.

**Acceptance:** preserve ordinary files and existing snapshots in supported preconfigured CachyOS layouts; cancellation and detection failures leave the original mount/configuration intact; a populated layout opens a valid confirmation instead of terminating the wizard.

### R03 — P1: A signature comment is wrongly treated as ownership of an entire file

**Evidence:** `lib/common.sh:178–205`; `lib/uninstall.sh:109–138,168–176`; `lib/runbooks.sh:222–225,244–247,270–273`. **Confirmed; adoption is newly introduced in the reviewed change range.**

Although `backup_file` identifies shared files, its signature branch records the whole file in the deletion manifest before considering that distinction. Any `.bashrc` containing the wizard hook is adopted. On uninstall, generic restoration can replace the entire current file with an older backup, discarding subsequent user edits. Moreover, shell-hook cleanup calls `backup_file` after deleting the manifest, recreating ownership records during uninstall and making a later uninstall hazardous.

The same adoption mechanism records regenerated recovery runbooks. Uninstall can then delete or revert those documents despite promising to preserve them. A signature is also not reliable provenance: an unrelated file mentioning the project name qualifies.

**Improve:** use typed ownership records: generated file, managed block in shared file, preserved recovery document, directory, subvolume, and unit. Never adopt shared files or runbooks into a whole-file deletion list. Make backup creation independent of ownership registration, especially during uninstall. Record ownership only after the authorized mutation succeeds.

**Acceptance:** repeated setup/uninstall preserves unrelated shell edits and current runbooks, does not recreate a deletion manifest, and does not acquire ownership from a mere project-name comment.

### R04 — P1: Broad archive cleanup contradicts the backup-preservation promise

**Evidence:** `templates/os-cloud-backup.sh:25–26`; `lib/uninstall.sh:151–154,195–199`. **Confirmed.**

The uploader deletes all `*.btrfs.zst*` files in the shared OS backup directory before starting. Uninstall also deletes all matching compressed/encrypted streams there. Neither distinguishes a temporary interrupted upload from an intentionally retained recovery artifact. The glob alone cannot prove that data is disposable.

**Improve:** use a private, per-run spool directory with an explicit temporary-file ledger. Clean only files created by that run or verified abandoned spools. Keep backup artifacts outside generic configuration uninstall.

**Acceptance:** unrelated streams, manually retained archives, and active-run artifacts survive setup/uninstall; only owned abandoned temporary artifacts are cleaned.

### R05 — P1: Recovery reuses subvolume IDs that no longer identify the restored root

**Evidence:** `lib/runbooks.sh:63–65`; `templates/rollback-runbook.txt:384`; `templates/bare-metal-runbook.txt:215–223`; `templates/cloud-recovery-runbook.txt:279–284`. **Confirmed; failure depends on the source mount/fstab containing IDs.**

The mount-options sanitizer removes `subvol=` but retains `subvolid=`. The generator probe produced `rw,subvolid=256`; rollback then adds `subvol=@` for a newly created snapshot with a different ID. Btrfs requires both options to identify the same subvolume. Separately, bare-metal/cloud recovery replaces filesystem UUIDs in the copied fstab but leaves old subvolume IDs unchanged. The result can fail mounting or booting after an otherwise successful restore. See the [Btrfs mount-option contract](https://btrfs.readthedocs.io/en/latest/btrfs-man5.html).

**Improve:** strip both source identity options from reusable mount options. Rewrite all restored Btrfs fstab entries to verified destination paths or newly discovered IDs, including rollback. Audit boot entries for the same assumption.

**Acceptance:** restore and boot a source using both `subvol` and `subvolid`, with deliberately different destination IDs; every mounted path resolves to the intended destination subvolume.

### R06 — P1: Snapshot layout detection consumes metadata that detection deliberately removes

**Evidence:** `lib/detect.sh:110–118`; `lib/runbooks.sh:202–209`; snapshot placeholder sections in both bare-metal/cloud runbooks. **Confirmed.**

Detection excludes `@snapshots` and `.snapshots` from the backed-up subvolume list. Runbook generation later searches that same list for `@snapshots`/`@.snapshots`, so those branches cannot represent the normal detected layout. It falls back to a nested root path. Recovery creates directories rather than reconstructing a separate top-level snapshot subvolume, while the restored fstab can still require that missing top-level subvolume.

**Improve:** maintain separate inventories for backup-eligible data and complete mount/layout metadata. Persist the actual Snapper layout, recreate required empty subvolumes, and reconcile restored fstab entries. Do not make recovery topology depend on whether a resource's contents are backed up.

**Acceptance:** recover and boot nested, `@snapshots`, and `@.snapshots` layouts using real detection output, not hand-built lists that include otherwise filtered entries.

### R07 — P1: Cloud recovery checks the filesystem while it is still mounted

**Evidence:** `templates/cloud-recovery-runbook.txt:141,203–206,235`. **Confirmed.**

The target is mounted for receiving data; `btrfs check --readonly` runs before the later unmount. Without `--force`, the checker refuses a mounted filesystem, causing this runbook's fatal branch on a normal restore. `--readonly` is not permission to check a mounted filesystem. See the [Btrfs checker documentation](https://btrfs.readthedocs.io/en/latest/btrfs-check.html).

**Improve:** finish writes, sync, unmount all target mounts, run the read-only check, then remount for the next phase. Do not simply add `--force` to a live writable target.

**Acceptance:** execute this sequence against a disposable Btrfs filesystem and reach the subsequent recovery step without bypassing the integrity gate.

### R08 — P1: Cloud recovery drops detected kernel metadata and ignores the selected archive

**Evidence:** `lib/runbooks.sh:70–76`; `templates/bare-metal-runbook.txt:242`; `templates/cloud-recovery-runbook.txt:313–325,398–415`. **Confirmed.**

The generator discovers and exports the kernel/microcode package list, and the local runbook renders it. The cloud runbook instead exports `${KERNEL_PKGS:-}` and exits when empty. On fresh recovery media, following the executable commands requires a manual metadata repair rather than using information already available when the document was generated. The suggested pacman-log grep is also not a dependable installed-package inventory.

More decisively, the runbook requires `ARCHIVE_NAME` to be set but invokes Borg with the literal `"$REPO_PATH::<ARCHIVE_NAME>"`. Setting the instructed variable does not select the archive for extraction.

**Improve:** render the detected package list into the cloud recovery environment, with an explicit supported-kernel inventory and recovery override. Replace the quoted archive placeholder with the validated selection variable. Check all generated instructions for placeholders that disagree with surrounding variable checks.

**Acceptance:** a fresh recovery shell receives a nonempty correct package list; selecting an existing archive reaches extraction without editing command literals. Test custom supported kernel variants and microcode.

### R09 — P1: Borg cannot acquire its normal lock on the prescribed read-only cloud mount

**Evidence:** `templates/cloud-recovery-runbook.txt:365,396,405,414`. **Confirmed.**

Rclone mounts the repository read-only, but Borg list/check/extract use normal repository locking. Borg requires lock bypass for genuinely read-only repository storage. Adding bypass blindly is unsafe because the repository is also a mutable synchronization destination. The [Borg common-options documentation](https://borgbackup.readthedocs.io/en/stable/usage/general.html) explicitly requires excluding concurrent writers when bypassing locks.

**Improve:** preferably restore a completed generation to writable local storage and use ordinary locks. If read-only recovery is retained, pin an immutable generation and use the appropriate read-only/Borg options for the supported version; exclude writers for the entire recovery.

**Acceptance:** list, verify, and extract from the documented mount with an encrypted test repository; concurrent publication cannot change the selected generation.

### R10 — P1: Systemd expands `date +%s` as a unit specifier

**Evidence:** `templates/pika-cloud-sync.service:29`; `templates/pika-cloud-sync-stale-check.service:9`. **Confirmed by upstream syntax; not executed under systemd on this host.**

Both Exec commands contain an unescaped `%s`. Systemd interprets it as the service manager user's shell, even inside the quoted shell command. The success timestamp therefore is not the intended epoch; the stale check's arithmetic also receives an invalid value. ShellCheck of standalone scripts cannot detect this template-language defect. See [systemd's specifier definition](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.unit.xml).

**Improve:** use `%%s` in unit command text, or move the logic into a separately linted executable where `date +%s` has normal shell meaning. Make invalid timestamp output a failure, not healthy state.

**Acceptance:** run both rendered units under systemd; the success state contains a numeric epoch, and an expired epoch causes a retry/alert. Include a rendered-unit verification gate.

### R11 — P1: Empty configured state means both “nothing succeeded” and “use selected layers”

**Evidence:** `lib/common.sh:71–83`; `wizard.sh:824–859`; `lib/validate.sh:112–114`. **Confirmed.**

`layer_configured` falls back to selected layers when the configured array is empty. That is also the valid runtime state after all earlier setup attempts failed. A downstream layer can therefore accept a failed prerequisite. The probe showed Layer 2 accepted with selected layers `(2 4)` and no successes, but rejected when unrelated Layer 1 had succeeded. Dependency truth must not depend on an unrelated success.

Conversely, post-setup Layer 2 validation is gated on configured rather than selected/attempted state, so a failed selected Layer 2 can be skipped when another layer succeeded. Setup errors are logged but not accumulated into a durable outcome model.

**Improve:** represent requested, attempted, configured, and failed states separately; distinguish standalone validation explicitly rather than through array emptiness. Block downstream setup on real prerequisite outcomes, validate every requested layer, and return failure if any required setup failed.

**Acceptance:** cover every prerequisite failure combination, including zero successes and an unrelated success; failed selected layers remain visible and make the overall outcome unsuccessful.

### R12 — P1: A partial OS upload is reported as a complete, fresh recovery copy

**Evidence:** `templates/os-cloud-backup.sh:28–43,75–105,115–117`. **Confirmed.**

Missing snapshots are warnings and skipped. Success only requires `uploaded_count > 0`, so home alone can upload while the root snapshot is absent, followed by “Your OS clone is safe” and the nag-suppression stamp. Snapshot age and a complete generation are not checked. Pruning even runs before the zero-upload failure check.

**Improve:** verify the expected mounted backup UUID, require root plus every declared required subvolume, enforce freshness, and publish a completed generation manifest only after all objects pass verification. Stamp success and prune only after that complete generation is recoverable. Distinguish optional omissions from failure explicitly.

**Acceptance:** missing root, one missing required subvolume, stale input, wrong/unmounted backup target, and a failed transfer all return failure and do not update freshness or retire the last complete generation.

### R13 — P1: Generic Borg failures are mislabeled as repository verification

**Evidence:** `lib/layer3_pika.sh:210–221`; `lib/validate.sh:206–220`. **Confirmed.**

The code assumes Borg exit code 2 means “passphrase required.” In legacy exit-code mode it means generic fatal error, including permission, locking, corruption, or other exceptions. Directory markers plus any exit 2 are accepted as verified. Setup additionally accepts timeout 124 and prints “repository verified,” whereas validation rejects that timeout. See [Borg return codes](https://borgbackup.readthedocs.io/en/stable/usage/general.html).

**Improve:** identify authentication-required outcomes specifically for the supported Borg version, retain diagnostics, and report locked/unverified repositories as unknown or blocked rather than verified. Do not claim schedule or archive success from GUI confirmation and directory markers.

**Acceptance:** authentication needed, incorrect credentials, permission denied, repository corruption, lock contention, timeout, and success produce distinct truthful results. Only an actual successful verification is labeled verified.

### R14 — P1: Health checks can be green without any completed backup

**Evidence:** `lib/validate.sh:129–138,317–354`; `templates/pika-cloud-sync-stale-check.service:5`. **Confirmed omissions.**

Layer 4 ignores a missing, malformed, empty, or future-dated success timestamp. It only recognizes a literal `ActiveState=failed`, which is insufficient for a retrying service. It checks the main timer but not whether the stale-check service exists or its timer is enabled/active. The stale-check unit's condition excludes missing state entirely, so a configuration that never succeeded is not covered by that guard.

Layer 2 largely checks configuration/timer presence and dry-run validity, not the last successful backup or freshness/completeness of received targets. Layer 5 validation likewise needs to prove the expected mounted filesystem rather than just a directory's existence.

**Improve:** define freshness and completion invariants per layer. Validate systemd Result/last execution plus a trustworthy success record, required target data, expected UUID, first-run grace period, and auxiliary timer health. Unknown or invalid state must not silently pass.

**Acceptance:** timers enabled but never successful, auto-restarting failures, missing/corrupt/future state, stale received snapshots, and missing auxiliary units all produce actionable non-green results.

### R15 — P1: Persisted retention is shadowed by startup defaults

**Evidence:** `lib/common.sh:25–31,158–168`; `wizard.sh:14–27`; `tests/test_common.sh:183–200`. **Confirmed; newly introduced retention/persistence integration defect.**

Common-library initialization assigns every retention variable before `load_settings`. The loader skips any variable already set, so saved custom retention never overrides those defaults in a fresh ordinary process. The test explicitly unsets the variables before loading, bypassing the actual startup sequence. A saved longer policy can consequently be replaced with shorter defaults and subsequently persisted again.

**Improve:** load saved settings before applying fallback defaults; distinguish explicit environment/CLI overrides from internally assigned defaults. Validate retention values and make precedence an explicit documented contract.

**Acceptance:** launch a fresh process with no retention environment variables and saved nondefault values; generated local/cloud policies match those saved values. Test explicit overrides and invalid/zero/negative cloud retention separately.

### R16 — P1: Template installation can report success after a failed write

**Evidence:** `lib/common.sh:220–280`; `wizard.sh:829–832`; `lib/runbooks.sh:225–229,247–255,273–280`. **Confirmed.**

`template_render` does not explicitly check the final printf, chmod, or rename. It then logs success and can return success through its later commands. Layers run with `set +e`, and commands inside conditional function calls cannot safely rely on `errexit` either. The resulting configuration may be missing, stale, or partially rendered while subsequent setup continues. Runbook callers also announce generation without consistently checking renderer success.

Early renderer returns do not restore the changed shell option; failed temporary files are not consistently cleaned. The backup helper records original/adopted ownership before the backup operation and authorization have fully succeeded.

**Improve:** check every critical operation, propagate the original failure, restore process state on every exit, and clean only owned temporary files. Validate the rendered artifact before replacement; register ownership and announce success only after installation succeeds.

**Acceptance:** inject full-disk, write, chmod, rename, missing-variable, and invalid-output failures. The old output remains usable, the function returns nonzero, no success is logged, and shell options/ownership state are unchanged.

### R17 — P1: Different filesystem device IDs do not prove independent physical disks

**Evidence:** `lib/layer2_btrbk.sh:62–80`; `lib/detect.sh:297–305`; candidate ancestry checks in `wizard.sh:283–305,336–358`. **Confirmed logical gap.**

Layer 2 claims to enforce different physical devices using `stat -c %d`. Different partitions/filesystems on the same disk have different filesystem device IDs, yet share the failure domain. Existing backup discovery compares exact device nodes against system devices rather than consistently applying the parent/leaf ancestry check used by the new-drive selection paths. A preexisting sibling partition can therefore evade the physical-separation promise.

**Improve:** resolve all physical backing devices for source and target, including multi-device Btrfs, LVM, dm-crypt, and aliases; reject intersecting leaf-device sets. Use one shared guard for both discovered and newly selected backup targets. Treat unresolved topology as unknown, not proven safe.

**Acceptance:** sibling partitions are rejected; separate disks accepted; stacked and multi-device layouts are evaluated accurately; missing topology never produces a physical-independence claim.

### R18 — P1: Fstab replacement is not one validated transaction

**Evidence:** `wizard.sh:551–579`; `lib/uninstall.sh:64–69`. **Confirmed.**

Replacing a stale backup entry first commits a cleaned fstab, then constructs and verifies the final replacement. A later failure leaves the original entry removed. Uninstall proceeds with in-place edits even after backup creation fails and suppresses edit failures while logging removal. Individual atomic renames do not make a multi-stage operation transactional.

**Improve:** construct the complete intended fstab once, validate it, create a verified backup, and perform one checked replacement. On cancellation or failure, leave the original untouched. Do not rewrite shared system configuration after a failed required backup.

**Acceptance:** fault-inject each stage of stale-entry replacement and uninstall; every failed operation preserves the original fstab byte-for-byte, including unrelated entries and managed-block boundaries.

### R19 — P1: Uninstall disables unowned services, misses auxiliary timers, and discards retry state

**Evidence:** `lib/uninstall.sh:40–53,102–140,157–158,194–203`. **Confirmed.**

Snapper/btrbk/Limine services are disabled unconditionally, even if they predated the wizard or the manifest is absent. Restoring an original configuration does not restore its previous enabled/active state. The cloud stale-check timer is not disabled before its files are removed. Many cleanup failures are suppressed, the ownership manifests are deleted anyway, and the function always reports success, making a partial uninstall difficult to resume safely.

**Improve:** record prior unit states and manage only owned changes. Stop all owned main and auxiliary units before deleting files; restore prior states when restoring configuration. Retain failed-resource records, aggregate errors, and report partial completion honestly.

**Acceptance:** uninstall with no manifest leaves unrelated services alone; preexisting enabled services retain their prior state; all owned timers stop; failed removals/restorations leave a retryable ledger and a nonzero result.

### R20 — P1: The only cloud Borg copy is updated in place without a recovery publication boundary

**Evidence:** `templates/pika-cloud-sync.service:20–34`. **Inferred architectural risk; no repository corruption was induced.**

A read-only local snapshot stabilizes the source, but `rclone sync` mutates a single destination tree. An interrupted transfer can leave files from different repository generations without a marker identifying a verified recoverable generation. Local snapshot cleanup also runs on failure. The delete limit is not a transaction or a backup-history policy. Rclone documents destination updates and deletion behavior, not atomic publication of a whole repository; it also avoids deletion after errors, which does not undo files already updated. See the [rclone sync contract](https://rclone.org/commands/rclone_sync/).

**Improve:** retain a previous verified generation using versioned destinations or suitable provider versioning, upload into a staging generation, verify repository recoverability, and publish a completion marker/pointer last. Define recovery behavior during an interrupted update and coordinate readers with publication.

**Acceptance:** interrupt synchronization at multiple transfer stages; the documented recovery process still finds and extracts from the previous complete generation. Test provider-specific versioning and cleanup guarantees explicitly.

### R21 — P1: Filename-based template escaping does not cover actual command contexts

**Evidence:** `lib/common.sh:250–260`; `templates/pika-cloud-sync.service:19,23,27`; `lib/runbooks.sh:190–192`; `wizard.sh:450`. **Confirmed escaping gap; command execution is an inferred consequence for hostile values.**

Shell-script outputs escape shell metacharacters, but service/config outputs only escape double quotes and text runbooks receive raw values. A mount path containing a dollar expansion or backticks can pass the mount-input filter and then be embedded inside `sh -c` in a privileged unit. Outer unit quoting does not protect it from the invoked shell. Generated recovery command blocks likewise interpolate path/subvolume values into executable double-quoted shell text without context-aware escaping. Configuration formats, unit arguments, and shell fragments do not share a quoting language.

**Improve:** move privileged command sequences into separately tested scripts taking literal arguments; use explicit rendering functions for each remaining syntax context. Validate discovered as well as entered values. Do not use the output filename extension as the security model.

**Acceptance:** render and execute harmless fixtures containing spaces, dollar signs, quotes, backticks, glob characters, and permitted punctuation. Paths remain literal; no substitution occurs. Test through systemd's parser, not only a direct shell.

### R22 — P1: Tests and VM tooling do not establish the claimed recovery contracts

**Evidence:** `tests/test_uninstall.sh:39–96`; `tests/test_common.sh:183–200`; `vm-test-cachyos/cidata/run_vm_tests.sh:240–284`; `Makefile`; `.github/workflows/lint.yml`. **Confirmed coverage defects; target suite execution remains unverified here.**

Uninstall tests duplicate fragments of the algorithm rather than calling the production uninstall function, so they cannot catch its ordinary-file deletion or lifecycle bugs. The retention test avoids the real startup sequence. The VM Layer 4 path manually renders templates instead of running `setup_layer4`; required service variables such as `PIKA_BORG_REPO_REL` are established by that omitted setup. On rendering failure, the runner copies raw templates into unit files. Timer activation failure is ignored, and the final Layer 4 “rendered” result captures the later chown status rather than the aggregate contract.

The VM harness exercises selected components, but does not prove an offsite upload followed by a documented fresh-disk restore and boot. Fixture identities and mocked setup must not be represented as proof of real supported-distribution integration.

**Improve:** test production entry points with injectable paths/tools. Make every render/activation failure fail the harness; never install raw-placeholder fallback units. Add Linux integration tests executing rendered units and both encrypted/plain recovery paths, followed by a disposable CachyOS/Limine boot test. Keep mocked component tests clearly separate from end-to-end claims.

**Acceptance:** each R01–R21 failure case gets a regression test; CI fails on missing template variables, failed units, incomplete uploads, and failed restore boot. Publish test logs and state exactly which real components ran.

### R23 — P2: Lexical prefix sorting can choose older snapshots and retain the wrong archives

**Evidence:** `templates/os-cloud-backup.sh:39,92`; lookup blocks in `lib/runbooks.sh:84–172`. **Confirmed by a safe ordering probe.**

Hashed and legacy prefixes are intentionally accepted together, then full names are sorted in reverse. Prefix differences sort before dates: `@home_12345678.20260901T0000` wins over the newer `@home.20261001T0000`. Recovery and upload can select stale input; pruning can retain older hashed archives instead of newer legacy ones. Plain/encrypted variants of the same snapshot can also consume separate retention slots even when the policy is expressed as a number of OS clones.

**Improve:** parse and validate timestamps, normalize the source identity, and select by date/generation with a deterministic tie-breaker. Define whether retention counts files, snapshots, or complete recoverable generations; validate the count before deleting anything.

**Acceptance:** mixed legacy/hashed names, mixed encryption formats, duplicates, malformed dates, and equal timestamps select the newest valid generation and retain the intended number of recovery points.

### R24 — P2: Signal traps clean up but allow upload execution to resume

**Evidence:** `templates/os-cloud-backup.sh:17–18,22–23`. **Confirmed by a safe TERM probe.**

The same cleanup-only handler is installed for EXIT, INT, TERM, and HUP. A trapped signal does not automatically terminate a shell; the probe printed a subsequent command after TERM. Real continuation depends on the interrupted command, but cleanup can occur while later pruning/stamping logic remains reachable. Killing the keepalive shell also does not explicitly account for all pipeline workers.

**Improve:** keep idempotent cleanup on EXIT; have signal handlers terminate with the conventional nonzero status, stop/wait for owned children, and prevent publication/pruning after cancellation. Avoid interactive ERR prompts in any automated path.

**Acceptance:** send INT/TERM/HUP during compression, transfer, and idle phases; no child survives, no success state is written, and no last-known-good generation is removed. Temporary artifacts are cleaned safely.

### R25 — P2: CLI validation still fatally requires dialog

**Evidence:** `wizard.sh:765–768`; `lib/ui.sh:11–16`; `lib/validate.sh` backend initialization. **Confirmed.**

`detect_dialog ... || true` does not suppress `die`, because `die` exits the shell rather than returning a failed function status. On a headless or minimally provisioned system without dialog, CLI validation terminates before producing its health report. The later guard around displaying the dashboard does not solve startup dependency handling.

**Improve:** keep noninteractive validation independent of UI initialization. Make backend discovery return a status; reserve fatal dependency checks for interactive workflows. Preserve meaningful validation exit status and machine-consumable output.

**Acceptance:** real CLI invocation with no dialog, no TTY, missing configuration, and healthy/unhealthy fixtures prints results and returns the appropriate health status without opening a UI.

### R26 — P2: Pika-only cloud setup has no corresponding generated recovery guide

**Evidence:** `lib/runbooks.sh:263–265`; Layer 4's support for a configured Pika prerequisite. **Confirmed missing workflow.**

Layers 3+4 can configure home-data cloud sync without Layer 2, but cloud recovery runbook generation requires Layer 2. The user gets an offsite backup path without the corresponding personalized archive discovery, credentials, read-only handling, and restore instructions. Validation does not require a dedicated guide for this combination.

**Improve:** generate a focused Pika cloud recovery guide independently of OS cloning, including repository/generation location, Borg version, encryption key/passphrase prerequisites, and ownership restoration. Validate its existence for every applicable selection.

**Acceptance:** selecting 3+4 without 2 generates and verifies a usable home-data restore guide; recovery works from a fresh environment with only the documented prerequisites.

### R27 — P2: Supported scope and shell behavior are inconsistent

**Evidence:** distro/bootloader warning paths in `lib/detect.sh`; `lib/layer4_cloud.sh:365–373`; Limine-only recovery templates. **Confirmed; zsh handling was removed in the reviewed change range.**

The project now targets CachyOS with Limine, but unknown distro/bootloader detection still allows proceeding into Limine-specific recovery instructions. Separately, `bash | *` writes `.bashrc` for zsh and other shells. Removing a zsh branch as part of distro scope reduction is not equivalent to proving that all supported users run bash/fish; the nag hook can exist and validate while never being sourced by the user's actual shell.

**Improve:** enforce prerequisites for the features that require them, or clearly label unsupported/limited mode and omit misleading recovery instructions. Handle the actual supported shell set explicitly; for unsupported shells use documented desktop integration or fail that hook step without claiming success.

**Acceptance:** unsupported bootloaders never receive a purported verified Limine recovery guide; bash, fish, zsh, and unknown-shell cases either install an effective supported hook or report the limitation.

### R28 — P2: Settings persistence has no atomicity or centralized schema

**Evidence:** `lib/common.sh:147–170`. **Confirmed design debt.**

`save_settings` truncates the live file and appends variable declarations incrementally. Interruption or disk failure can destroy the previous valid state. Save/load duplicate a long variable list, with no schema version or shared validation. `eval` makes ownership and permissions of this root-consumed executable configuration especially important, but the loader does not enforce that trust boundary itself.

**Improve:** write a validated versioned settings snapshot to a same-directory temporary file and atomically replace it only on success. Centralize the variable schema and precedence rules; prefer a non-executable serialization or verify ownership/permissions and accepted types before evaluation. Separate detected runtime facts from user preferences.

**Acceptance:** interrupted/failed persistence leaves the last valid settings intact; invalid types/values and untrusted files are rejected; adding a field updates one schema and round-trip tests cover fresh-process loading.

### R29 — P3: Interface documentation contradicts production contracts

**Evidence:** `INTERFACE_MAP.md:35,46–51,58,79–85`; current libraries/templates/Makefile. **Confirmed.**

Examples include documenting `DETECTED_SUBVOL_MOUNTS` as a space-delimited subvolume string instead of an array of mount/subvolume pairs; listing a nonexistent `run_cmd`; describing template rendering as awk/sed; giving the wrong manifest filename; calling Deep Storage a subvolume although setup creates a directory; describing Pika sync as nightly and the stale guard as weekly although the templates specify weekly sync and daily checking; and listing scrub timers that the wizard does not install. Such errors encourage incorrect tests and maintenance changes.

**Improve:** synchronize the interface map with code, document exact return/status and ownership contracts, distinguish installed features from future plans, and qualify README claims about independent layers, backup preservation, and verified recovery until their guarantees are tested.

**Acceptance:** every documented global, helper, installed unit, schedule, resource type, and state path has a corresponding current implementation or is clearly marked as planned.

### R30 — P3: Global coupling, duplication, and long procedural blocks amplify defect risk

**Evidence:** `wizard.sh` (866 lines), `lib/layer4_cloud.sh` (503 lines), `lib/validate.sh` (504 lines), `lib/runbooks.sh` (334 lines); duplicated recovery and snapshot-name logic in templates. **Confirmed clean-code debt.**

The module split is useful, but major procedures still combine detection, UI, authorization, rendering, privileged mutation, validation, and reporting. Dynamically scoped globals carry context implicitly; configured state has multiple meanings; filename extensions select escaping rules; copied recovery blocks and duplicated hashing rules drift despite an advertised authoritative naming helper. Broad `|| true` suppressions and historical audit comments often substitute for an explicit failure policy.

**Improve:** after the safety fixes, extract small functions around observable contracts: detect plan, authorize plan, apply resource transaction, validate completion, publish outcome. Pass explicit context/arguments, centralize snapshot metadata and resource ownership, and share tested recovery fragments without creating a large generic framework. Give temporary mounts, locks, workers, and traps a clear lifecycle.

**Acceptance:** tests exercise the extracted production functions; each mutation declares rollback/cleanup and failure behavior; one naming implementation drives producers and consumers; routine cleanup failures are distinguishable from critical failures.

### R31 — P3: The normal quality gate omits VM scripts and runtime prerequisites

**Evidence:** `Makefile:6–14`; `.github/workflows/lint.yml`; supplemental lint result. **Confirmed.**

The ShellCheck target omits VM shell scripts, allowing that tooling to accumulate lint debt independently. `git diff --check` on a clean CI checkout does not inspect whitespace already committed in a PR. The test target invokes whichever `bash` is on PATH without a minimum-version check, so macOS contributors see an opaque parser failure before tests. The code also relies on GNU/Linux tools and flags, not a portable zero-dependency environment.

**Improve:** include VM scripts in lint, address warnings with narrowly justified suppressions only where appropriate, check the relevant committed diff in CI, and document/check the supported Bash/GNU-tool runtime. Supply a reproducible Linux development/test command without requiring changes to the user's host.

**Acceptance:** VM scripts are in the standard gate; a committed whitespace regression fails the PR check; unsupported local runtime produces a clear prerequisite message; documented Linux test instructions reproduce CI.

## Newly introduced or expanded technical debt

The local comparison with `29689a2` establishes the following changes; other findings should not automatically be blamed on the latest merge.

| Change | Introduced/expanded concern | Required cleanup |
| --- | --- | --- |
| Selectable persisted retention (`56bda9b`) | Retention fields were added to save/load but initialization defeats ordinary reload; auto-pruning increases the consequence of a wrong policy. | R15, R23, R28: test fresh-process precedence and generation-based retention before deleting remote history. |
| Signature-based adoption in `backup_file` | Shared files and preserved runbooks become whole-file deletion/restoration targets. | R03: typed ownership, separate backup and adoption operations, repeat-install/uninstall tests. |
| CachyOS/Limine scope reduction (`61f7494`, `03f7ea0`) | zsh hook support was removed although distro scope does not establish user shell; remaining soft platform checks disagree with hardcoded guides. | R27: explicit supported feature/shell boundaries and matching recovery output. |
| Repeated audit/VM fixes | CLI UI display guards and runner exit propagation improve individual symptoms, but do not prove headless startup or real Layer 4 execution. | R22, R25, R31: execute real entry points and rendered artifacts, not substitute algorithms or fallback templates. |

Positive recent changes should be retained: generic manifest processing now explicitly skips `/etc/fstab`; dry-run simulation has terminating signal handlers; layer dependency checks and safer naming were introduced; and the VM runner has better failure propagation. The report does not reassert removed GRUB/Ubuntu support as missing functionality or require widening the stated platform scope.

## Recommended remediation sequence

1. **Contain destructive behavior:** R01–R04. Disable automatic unowned/nonempty resource deletion and whole shared-file adoption. Add production-path regression tests before refactoring these operations.
2. **Repair executable recovery contracts:** R05–R10 and R21. Test on disposable disks, including preserved layout, different IDs, fresh shells, encryption, and actual systemd parsing.
3. **Make outcomes truthful:** R11–R19. Introduce explicit failure/completion state, correct retention precedence, checked atomic writes, physical-separation checks, and retryable uninstall.
4. **Prove offsite recoverability:** R20 and R22. Preserve verified generations and demonstrate interrupted-sync survival plus fresh-disk restore and boot.
5. **Finish operational workflows and clean the campsite:** R23–R31. Fix ordering/signals/headless behavior, fill recovery-guide gaps, then simplify repeated logic and synchronize docs/CI.

### Release-quality acceptance checklist

- No destructive operation acts on unowned or unexpectedly populated resources without separate informed authorization.
- Cancellation or failed writes preserve the original fstab, settings, user shell content, and prior configuration.
- Required setup failures cannot disappear as skipped checks or successful downstream setup.
- Backup freshness means a complete, verified generation, not merely a timer/configuration or one uploaded subvolume.
- An interrupted cloud update still leaves a documented known-good recovery point.
- Generated recovery instructions execute on fresh supported media and boot the restored CachyOS/Limine installation.
- Repeated setup and uninstall preserve user edits, retained backups, runbooks, and preexisting service states.
- CI exercises the production paths and rendered artifacts that implement these guarantees.

Until these conditions are demonstrated, the appropriate quality label is **promising implementation with significant safety and recoverability gaps**, not verified production-grade backup software.
