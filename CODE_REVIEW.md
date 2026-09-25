# Code Review — Arch Backup Wizard

**Review date:** 2026-09-25

**Reviewed range:** `761e644eb8ae55c904a1f31dd6a674da5ecd6639^..a77d1a6` (the requested commit, inclusive, through current `HEAD`)

**Scope:** all changed production code, templates, recovery runbooks, tests, documentation, and CI; adjacent code was followed where needed to verify cross-module contracts.

**Priority:** correctness first, performance second, code quality third.

**Method:** Boy Scout Rule — review the changed area in context and identify the smallest fixes that leave the backup, restore, and maintenance workflows safer than they were found.

## Executive summary

The range adds substantial hardening, encryption, broader subvolume coverage, validation, and a useful test harness. However, the current revision is not ready to promise working offsite or disaster recovery. Two cross-module regressions are release-blocking:

1. btrbk now appends a hash to every snapshot name, but the OS uploader and both recovery generators still search for the old unhashed names. The cloud uploader finds no snapshots, and the bare-metal recovery script silently creates empty subvolumes instead of restoring data.
2. Layer 4 no longer assigns the selected rclone remote to `CLOUD_REMOTE`. Generated jobs therefore lose the remote prefix, and recovery-runbook generation is skipped.

The Pika offsite path is also non-functional: the service checks the parent `Personal` directory as though it were a Borg repository, while Layer 3 creates the repository one level below it. In addition, the timer requires a state file that only a successful first run can create, so the scheduled first run cannot occur.

**Release recommendation:** do not release the current revision as a production backup/recovery tool until ABW-R1 through ABW-R6 are fixed and exercised in a disposable Arch VM with a real backup and full restore.

## Finding index

| ID | Severity | Priority | Area | Finding |
|---|---|---|---|---|
| ABW-R1 | **Critical** | Correctness | Snapshot contract | Hashed btrbk names no longer match upload or recovery lookups |
| ABW-R2 | **Critical** | Correctness | Cloud configuration | The selected rclone remote is never exported into generated artifacts |
| ABW-R3 | **High** | Correctness | Pika offsite | The sync service validates the wrong Borg repository path |
| ABW-R4 | **High** | Correctness | Scheduling | The Pika timer cannot bootstrap its first run |
| ABW-R5 | **High** | Correctness | Cloud recovery | The generated restore script uses a private-key path that contradicts its instructions |
| ABW-R6 | **High** | Correctness | Failure handling | `set +e` allows failed configuration writes to be reported as successful layers |
| ABW-R7 | **Medium** | Correctness | Dry run | Dry-run aborts on an unformatted whole-disk target |
| ABW-R8 | **Medium** | Correctness | Runbook generation | Undefined template variables silently produce a malformed rollback command |
| ABW-R9 | **Medium** | Correctness | Validation | Validation can emit “All checks passed” after recording a Pika failure |
| ABW-R10 | **Medium** | Reliability / performance | Pika sync | An unbounded rclone run can permanently wedge future syncs |
| ABW-R11 | **Medium** | Performance | OS cloud backup | Every run uploads full images and remote retention is unbounded |
| ABW-R12 | **Medium** | Code quality | Quality gates | CI omits tests and executable templates; current local tests are not green |

## Detailed findings

### ABW-R1 — Hashed btrbk names no longer match upload or recovery lookups (**Critical**)

**Locations:** `lib/layer2_btrbk.sh:149-160`, `lib/layer2_btrbk.sh:191-198`, `templates/os-cloud-backup.sh:27-39`, `lib/runbooks.sh:78-98`, `lib/runbooks.sh:113-134`

Layer 2 now names every snapshot using a sanitized subvolume name plus an eight-character MD5 suffix:

```bash
subvol_safe="${subvol_safe}_${_hash}"
snapshot_name "${subvol_safe}"
```

The consumers did not adopt that naming rule:

- the OS cloud job searches for `${sub_safe}.20*`;
- bare-metal recovery searches for `${sub_safe}.*`;
- cloud recovery searches archive names beginning with `${sub_safe}.`.

A snapshot such as `@_7d...20260925T...` cannot match any of those patterns because the consumers expect a dot immediately after `@`. The cloud job reaches `uploaded_count=0` and exits. More seriously, the bare-metal recovery generator treats every miss as normal and creates an empty subvolume. It can therefore replace a restore with a superficially complete but data-empty layout.

**Required fix:** make snapshot identity a single producer/consumer contract. Prefer emitting a machine-readable mapping from source subvolume to `snapshot_name` and rendering that mapping into both jobs and runbooks. At minimum, use one shared naming helper everywhere. Recovery must fail closed if any required subvolume has no matching snapshot; it must never create an empty required root/data subvolume. Add a round-trip test that generates btrbk names, creates representative target entries, and proves both local and cloud recovery select the same entries.

### ABW-R2 — The selected rclone remote is never exported into generated artifacts (**Critical**)

**Locations:** `lib/layer4_cloud.sh:135-156`, `lib/layer4_cloud.sh:244-253`, `lib/layer4_cloud.sh:327-345`, `lib/common.sh:172-188`, `templates/os-cloud-backup.sh:51-55`, `templates/pika-cloud-sync.service:29`, `lib/runbooks.sh:55-58`, `lib/runbooks.sh:225-258`

Layer 4 stores the chosen remote only in the local variable `rclone_remote`. Before rendering the OS script and Pika service it exports `BACKUP_MOUNT` and the destination directory, but no longer does:

```bash
export CLOUD_REMOTE="$rclone_remote"
```

`template_render` substitutes an unset placeholder with an empty string. As a result:

- the OS job renders `rclone copyto ... "<cloud-dir>/..."`, which is a local path rather than `remote:path`;
- the Pika service receives the same remote-less destination and fails or writes locally depending on its working directory and permissions;
- `generate_runbooks` sees an empty `CLOUD_REMOTE` and skips the cloud recovery runbook entirely;
- the Layer 4 completion dialog still prints the correct local variable and claims the pipeline is ready.

This regression is visible in the reviewed diff: both former `export CLOUD_REMOTE="$rclone_remote"` assignments were removed.

**Required fix:** validate the remote once, then assign and export `CLOUD_REMOTE` before rendering any artifact or calling `generate_runbooks`. Make `template_render` reject missing required variables instead of silently substituting an empty value. Add a rendered-artifact test asserting that every rclone destination contains the exact selected `remote:` prefix.

### ABW-R3 — The Pika sync service validates the wrong Borg repository path (**High**)

**Locations:** `lib/layer3_pika.sh:54-76`, `templates/pika-cloud-sync.service:23-29`

Layer 3 creates and validates the Borg repository at:

```text
<backup-mount>/Personal/backup-<host>-<user>
```

The Pika cloud service instead sets `REPO` to the parent directory:

```text
<backup-mount>/.pika_sync_snapshot/Personal
```

and requires `config` and `data` directly beneath it. A correctly initialized Layer 3 repository therefore fails the service's `ExecStartPre` guard every time. No Pika data reaches the cloud. Layer 3 also returns success when the user says configuration is unfinished and repository validation fails, allowing this broken dependent layer to be installed.

**Required fix:** persist the actual repository relative path from Layer 3 and render it into the service. Validate and sync that exact directory, or intentionally sync the parent while validating that it contains exactly the expected repository child. Layer 3 should return non-zero until the configured repository exists and passes the chosen verification policy.

### ABW-R4 — The Pika timer cannot bootstrap its first run (**High**)

**Locations:** `lib/layer4_cloud.sh:334-340`, `templates/pika-cloud-sync.timer:1-8`, `templates/pika-cloud-sync.service:30-34`, `templates/pika-cloud-sync-stale-check.service:1-9`, `templates/pika-cloud-sync-stale-check.timer:1-11`

Setup creates `/var/lib/pika-cloud-sync/enabled`, but the timer also has:

```ini
ConditionPathExists=/var/lib/pika-cloud-sync/state
```

The `state` file is written only by `ExecStartPost` after a successful sync. Thus the timer requires evidence of a previous successful run before it can perform the first run. Reboots do not resolve the cycle.

The added stale-check service/timer cannot recover it: neither file is installed or enabled by Layer 4, and the stale-check service itself has the same `ConditionPathExists=.../state` bootstrap problem.

**Required fix:** remove the success-state condition from the main timer. Treat a missing state file as “never succeeded” inside the service or monitor. Install, enable, validate, and uninstall the stale-check units if they remain part of the design. Add a clean-machine test proving that enabling the timer with no state file results in a first attempted sync.

### ABW-R5 — The generated restore script uses the wrong Age private-key path (**High**)

**Locations:** `lib/layer4_cloud.sh:40-67`, `lib/runbooks.sh:55-59`, `lib/runbooks.sh:104-138`, `templates/cloud-recovery-runbook.txt:143-172`

Setup sets `CLOUD_AGE_KEY` to the installed system's path, normally:

```text
/home/<user>/.config/arch-backup-wizard/cloud_os.key
```

The generated cloud restore script embeds that value in `age -d -i`. The recovery runbook, however, instructs the operator to restore the escrowed key to `/root/cloud_os.key` in the live environment. In the disaster scenario the original `/home/...` path does not exist yet, so decryption fails even when the user follows the instructions exactly.

**Required fix:** separate the setup-time private-key path from the recovery-time key path. Render `/root/cloud_os.key` (or a clearly prompted recovery variable) into the runbook, quote it, and add a test that follows the documented live-environment path.

### ABW-R6 — `set +e` allows failed configuration writes to be reported as successful layers (**High**)

**Locations:** `wizard.sh:784-812`, `lib/layer1_snapper.sh:144-207`, `lib/layer2_btrbk.sh:136-211`, `lib/layer4_cloud.sh:250-281`, `lib/layer4_cloud.sh:334-359`

`run_layer` disables `errexit` around every setup function. The setup contract therefore requires every mutation to check and propagate its own status, but several critical operations remain unchecked. Examples include the Snapper and btrbk heredoc writes and multiple `chmod`, `chown`, `mkdir`, and `touch` calls in Layer 4. A failed operation is followed by logging or manifest recording that returns zero, and the layer eventually returns success.

This can leave truncated/missing configuration while the completion dialog says the layer succeeded. Runbooks are also generated from selected layers, not successfully configured layers.

**Required fix:** use checked write/install helpers for every managed artifact, write to a temporary file, validate, then atomically replace. Track `selected`, `configured`, and `verified` layers separately; generate dependent jobs and runbooks only from verified prerequisites. Add fault-injection tests for unwritable destinations and failed ownership/mode changes.

### ABW-R7 — Dry-run aborts on an unformatted whole-disk target (**Medium**)

**Locations:** `wizard.sh:398-420`, `wizard.sh:483-495`

In dry-run mode `_format_backup_drive` logs the simulated format and returns without changing `BACKUP_DEV`. The caller immediately executes:

```bash
BACKUP_UUID=$(blkid -s UUID -o value "$BACKUP_DEV")
```

An unformatted disk has no UUID, so `blkid` returns non-zero and the top-level `set -e` aborts the simulation before its preview. This is one of the most important paths to simulate because it precedes destructive partitioning.

**Required fix:** assign an explicit synthetic UUID and predicted partition path during dry-run, or bypass all post-format probing and mount work with a modeled target object. Add fixtures for an unformatted SATA disk and an NVMe disk.

### ABW-R8 — Undefined template variables silently produce a malformed rollback command (**Medium**)

**Locations:** `lib/common.sh:150-189`, `lib/runbooks.sh:40-67`, `templates/rollback-runbook.txt:389-405`, `templates/cloud-recovery-runbook.txt:8-20`

`rollback-runbook.txt` uses `{{ROOT_MOUNT_OPTIONS}}`, but `generate_runbooks` never defines or exports it. `template_render` replaces missing variables with an empty string, producing:

```text
mount -o subvol=<root>, UUID=<root-uuid> /mnt/target
```

The intended original root mount options are lost and the option list contains a dangling comma. `cloud-recovery-runbook.txt` similarly references undefined `ROOT_LABEL`, leaving misleading blank system metadata.

**Required fix:** maintain an explicit schema of required and optional variables per template. Fail rendering when a required variable is unset, and add a post-render assertion that no empty critical command fragments remain. Detect and export the root mount options deliberately rather than introducing an undeclared placeholder.

### ABW-R9 — Validation can emit “All checks passed” after recording a Pika failure (**Medium**)

**Locations:** `lib/validate.sh:194-239`, especially `lib/validate.sh:215-225`; `lib/validate.sh:244-340`

When `borg info` times out, validation appends a failure issue but never sets `l3_ok=false`. The layer and global result therefore remain successful, and the final dashboard can say “All checks passed!” while silently discarding the collected issue list.

Layer 4 validation also checks only that the Pika unit files exist and the timer is enabled/active. It does not validate the rendered destination, repository path, timer conditions, last service result, last success timestamp, or remote content. Consequently, after the timer bootstrap is manually bypassed, the path mismatch in ABW-R3 can still pass validation.

**Required fix:** distinguish warnings from failures structurally and derive the final result from that structure. Validate rendered unit semantics and service state (`Result`, `ExecMainStatus`, success timestamp), plus an actual remote listing for the configured destination.

### ABW-R10 — An unbounded rclone run can permanently wedge future Pika syncs (**Medium**)

**Locations:** `templates/pika-cloud-sync.service:8-13`, `templates/pika-cloud-sync.service:17-38`, `templates/pika-cloud-sync.timer:5`, `templates/pika-cloud-sync-stale-check.service:9`

The service sets `TimeoutStartSec=infinity`, while its rclone command has no connection or transfer timeout. A blackholed connection or stuck filesystem can therefore leave the service running indefinitely, retaining the read-only snapshot and `/run/pika-cloud-sync/active`. The timer explicitly refuses to trigger while that lock exists.

Even if the stale-check units were installed, they merely ask systemd to start the same already-active service; they do not stop or recover it.

**Required fix:** use bounded systemd and rclone timeouts, ensure termination cleans up state, and add an `OnFailure=` notification/recovery path. The monitor should detect an over-age active invocation, not just an old success timestamp.

### ABW-R11 — OS cloud uploads are full and remote retention is unbounded (**Medium**)

**Locations:** `templates/os-cloud-backup.sh:27-64`, `lib/layer2_btrbk.sh:141-198`

For every detected subvolume, every bi-weekly run performs a full `btrfs send`, compresses with `zstd -T0`, encrypts it, and uploads a new timestamped object. No incremental parent is used and no remote retention/pruning policy exists. After the correctness defects are fixed, network transfer, CPU use, and cloud storage will grow with the full protected dataset on every run and accumulate indefinitely.

**Required fix:** define an explicit remote retention policy and enforce it only after a verified upload. Consider incremental sends with carefully retained parent chains, or document full-image behavior and provide a bounded generation count. Apply `nice`/`ionice` or a controlled zstd thread count for a background-friendly profile.

### ABW-R12 — CI omits tests and executable templates; current local tests are not green (**Medium**)

**Locations:** `.github/workflows/lint.yml:1-11`, `Makefile:1-9`, `tests/test_common.sh:44-110`, `tests/test_helper.bash:136-190`, `tests/test_packages.sh:96-107`, `tests/test_validate.sh:67-82`, `README.md:213-227`

The only GitHub workflow runs a mutable ShellCheck action and explicitly ignores `templates`. It never runs `make test`. The local `make check` target also omits `templates/*.sh`, even though two templates become executable scripts and the systemd templates contain most of the broken offsite behavior.

The newly added tests do not cover Layer 2, Layer 3, Layer 4, generated services, or the producer/consumer naming contract. On the current development host, `make test` fails because of GNU-only `grep -P`, Bash-version assumptions, untrimmed `wc -l` output, and an incorrect Layer 5 fstab mock. One package test prints an internal `mapfile`/unbound-variable failure but is still reported as passed, demonstrating that the harness can mask failures.

**Required fix:** make CI run `make all`; lint rendered executable templates; validate systemd units; pin actions to immutable revisions; and add integration tests covering rendered Layer 4 artifacts, timer bootstrap, exact Borg repo paths, snapshot naming, and restore selection. If tests intentionally require Arch/GNU userland and Bash 4+, state that contract and run them in an Arch container/VM.

## Recommended remediation order

1. Establish one tested snapshot-name contract and make recovery fail closed (ABW-R1).
2. Restore `CLOUD_REMOTE` propagation and reject missing render variables (ABW-R2, ABW-R8).
3. Make Pika offsite target the actual repository and permit a first scheduled run (ABW-R3, ABW-R4).
4. Correct the recovery key path and prove OS/Pika restores in a disposable VM (ABW-R5).
5. Make layer success explicit and strengthen validation so partial configuration cannot be reported as healthy (ABW-R6, ABW-R9).
6. Repair dry-run, bound background work, and define cloud retention (ABW-R7, ABW-R10, ABW-R11).
7. Put all of the above contracts into CI (ABW-R12).

## Positive observations worth preserving

- Layer 4 now uses Age encryption for OS images and explicitly requires private-key escrow.
- Drive detection now canonicalizes system-device ancestry and filters whole disks with children/filesystem signatures.
- Layer 2 covers explicitly mounted Btrfs subvolumes instead of only the root subvolume.
- Cloud components are generated conditionally from their base-layer selections.
- Generated jobs use locks, read-only snapshots, checksums/size checks, and conservative failure cleanup.
- Recovery runbooks contain stronger post-restore structural checks than the earlier revision.
- The new fixture-based test harness is a good foundation once it is run in CI and expanded across layer boundaries.

## Verification performed

- `git diff --check 761e644^..HEAD` — passed.
- `bash -n wizard.sh lib/*.sh templates/*.sh` — passed.
- `make check` — passed with the locally installed ShellCheck, but this target does not inspect executable templates.
- `make test` — failed; failures reproduced separately in `test_common.sh`, `test_detect.sh`, `test_runbooks.sh`, and `test_validate.sh`. `test_packages.sh` reported pass despite an internal command failure.
- Static producer/consumer tracing of btrbk snapshot names, cloud variables, Pika repository paths, timer state, and every recovery-template placeholder.
- Manual read-only tracing of setup, dry-run, validation, uninstall, cloud upload, scheduled Pika sync, bare-metal restore, cloud restore, and rollback flows.

`systemd-analyze verify` was unavailable on this non-systemd host. No partitions, mounts, packages, system services, cloud remotes, or real backup data were modified. Full runtime verification still requires an Arch VM with disposable source/backup disks and a test cloud remote.
