# Code Review — Arch Backup Wizard

**Review date:** 2026-09-15

**Reviewed revision:** `d37ff59` (`bgra_review`)

**Scope:** `wizard.sh`, `lib/*.sh`, `templates/*`, `README.md`, `Makefile`, and CI configuration

**Focus:** correct backup/restore behavior, destructive-operation safety, usability, and bug hunting

**Method:** Boy Scout Rule — identify the smallest safe improvements that leave each touched workflow more reliable than it was found.

## Executive summary

The repository has a clear module structure and several good safety intentions, but it is **not production-safe in its current form**. The highest-risk problems are not style issues:

- the backup-drive picker can offer the running system disk as an “unformatted” target and then erase it;
- an unmounted or unrelated `fstab` entry containing the word “backup” can be accepted without verification, causing backups to be written onto the root filesystem;
- Layer 4 advertises encrypted offsite OS backups but uploads a merely compressed, plaintext Btrfs stream;
- the “OS clone” covers only the mounted root subvolume, while the generated recovery procedures assume hard-coded subvolumes and contain commands that restore data to the wrong place;
- validation can report “All checks passed” without proving that a backup exists, is current, is on the intended device, is encrypted, or is restorable.

These are release-blocking for a tool that partitions disks and promises disaster recovery. A safe next release should first make target selection fail closed, make the backup scope explicit, implement actual encryption, and exercise a full restore in a disposable VM.

## Finding index

| ID | Severity | Area | Finding |
|---|---|---|---|
| ABW-001 | **Critical** | Drive selection | The running system disk can be offered and erased as an “unformatted” backup disk |
| ABW-002 | **Critical** | Mount handling | Reusing an unverified/unmounted `fstab` entry can place backups on the root filesystem |
| ABW-003 | **Critical** | Cloud security | “Encrypted offsite” OS images are uploaded without encryption |
| ABW-004 | **High** | Backup scope | The Layer 2 “OS clone” omits separately mounted/nested Btrfs subvolumes |
| ABW-005 | **High** | Pika cloud copy | A live Borg repository is copied without a Borg lock and without producing an exact copy |
| ABW-006 | **High** | Recovery layout | Bare-metal/cloud runbooks ignore the detected layout and mishandle separate boot filesystems |
| ABW-007 | **High** | Cloud recovery | The cloud runbook hard-codes a received subvolume name that the backup never creates |
| ABW-008 | **High** | Home recovery | Borg extraction commands restore `home/<user>` underneath the user's home directory |
| ABW-009 | **High** | Snapper recovery | The rollback runbook cannot find the top-level snapshot layouts that setup explicitly supports |
| ABW-010 | **High** | Validation | Artifact-presence checks can produce a dangerously false healthy result |
| ABW-011 | **High** | State ownership | Setup overwrites existing configs and uninstall deletes/disables resources it did not prove it created |
| ABW-012 | **High** | Boot integration | GRUB and Limine integrations are incomplete while the UI claims they are active |
| ABW-013 | **High** | Dry run / modes | Dry-run has side effects, breaks on raw targets, and can be combined with real uninstall |
| ABW-014 | **High** | Error handling | Disabling `errexit` lets critical layer failures be overwritten by later successful commands |
| ABW-015 | **Medium** | OS cloud archive | Snapshot selection, concurrency, and retention can upload the wrong image or leave only one restore point |
| ABW-016 | **Medium** | Pika setup | The GUI instructions point at an empty directory and describe it as an existing repository |
| ABW-017 | **Medium** | Input/fstab safety | The mount path is not validated and only literal spaces are escaped for `fstab` |
| ABW-018 | **Medium** | Validation UX | Headless validation requires a dialog backend; Snapper-only runs can fail an irrelevant `fstab` check |
| ABW-019 | **Medium** | Layer dependencies | Layer 4 always creates a Pika sync job even when Layer 3 was not selected |
| ABW-020 | **Low** | CLI/docs | Documented CLI and validation behaviors do not match the implementation |
| ABW-021 | **Medium** | Quality gates | No behavioral tests cover destructive selection, generated configs, backup freshness, or restore procedures |

## Detailed findings

### ABW-001 — The running system disk can be offered and erased (**Critical**)

**Locations:** `lib/detect.sh:65-69`, `lib/detect.sh:118-127`, `wizard.sh:230-301`, `wizard.sh:331-351`

`detect_available_drives` puts **every** `TYPE=disk` device into `DETECTED_DRIVES`; it does not restrict the list to disks without partitions, filesystems, mounts, holders, or system dependencies. `select_backup_drive` calculates `dominated=true` when a disk already has a listed partition, but never acts on the value:

```bash
local dominated=false
for ((i=0; i<${#choices[@]}; i+=3)); do
    [[ "${choices[i]}" == "${dev}"* ]] && dominated=true && break
done

choices+=("$dev" "${size}  (UNFORMATTED — will partition)" "off")
```

Consequently a normal system disk such as `/dev/nvme0n1`, containing `/dev/nvme0n1p1` and the mounted root partition, is still shown as “UNFORMATTED — will partition”. Selecting it runs `parted ... mklabel gpt`, destroys the partition table, and then runs `mkfs.btrfs -f`.

There is a second root-filter failure: `findmnt -o SOURCE /` may include a Btrfs filesystem root suffix such as `/dev/nvme0n1p2[/@]`. The partition picker compares that string literally with `/dev/nvme0n1p2`, so the root partition can also remain selectable. `findmnt` provides `--nofsroot` specifically to suppress this suffix ([findmnt manual](https://man.archlinux.org/man/findmnt.8.en)).

The README also promises “double confirmation”, but the code has one default-No dialog.

**Required fix:** build the inventory from `lsblk --json` and resolve the complete dependency/parent chain for `/`, `/boot`, `/boot/efi`, `/efi`, active swap, and device-mapper/MD/LVM members. Exclude all of those devices and their parents. Only label a whole disk unformatted if it has no children, filesystem signature, mounts, or holders. Before destructive work, re-resolve the device, display model/serial/size/current layout, and require a typed device-name confirmation. Add unit fixtures for SATA, NVMe, LUKS-on-LVM, MD RAID, and Btrfs subvolume root output.

### ABW-002 — Reusing an unverified `fstab` entry can place backups on `/` (**Critical**)

**Locations:** `lib/detect.sh:134-150`, `wizard.sh:211-227`, `lib/layer2_btrbk.sh:26-35`, `lib/layer3_pika.sh:43-58`

Existing-backup detection selects the first uncommented `fstab` line whose mount path contains the substring `backup`. It does not verify that the entry belongs to this wizard, is Btrfs, is mounted, is writable, is a separate device, or even has a UUID. If the path is not currently mounted, `DETECTED_BACKUP_DEV` is empty.

When the user accepts that entry, `select_backup_drive` returns immediately. It bypasses `_ensure_backup_mounted`, filesystem verification, and UUID verification. The later layers only call `mkdir -p` below the path. An absent backup disk therefore causes `OS_Backup`, `Personal`, and `Deep Storage` to be created on the root filesystem; timers can then fill the system disk while presenting those directories as backups.

**Required fix:** store wizard ownership metadata rather than infer it from a path substring. On reuse, require `findmnt --mountpoint`, compare the mounted source and UUID with the intended `fstab` entry, require `FSTYPE=btrfs` for Layer 2, verify writability/free space, and reject a source on the root filesystem. Use `findmnt --target`/`--evaluate` rather than directory existence. Timer jobs must repeat the same device-identity check and fail before writing.

### ABW-003 — “Encrypted offsite” OS images are plaintext (**Critical**)

**Locations:** `wizard.sh:77-82`, `README.md:10-14`, `lib/layer4_cloud.sh:57-158`, `templates/os-cloud-backup.sh:18-27`

The UI and README call Layer 4 encrypted. The generated OS job does this:

```bash
sudo btrfs send "$snapshot" | pv | zstd >"$ARCHIVE_PATH"
rclone copy "$ARCHIVE_PATH" "provider-remote:path"
```

`zstd` is compression, not encryption. The wizard guides users to configure a direct Google Drive, OneDrive, Dropbox, or B2 remote and never creates or verifies an rclone `crypt` wrapper. The uploaded Btrfs stream contains the root filesystem, including system configuration and secrets, readable by anyone with access to the cloud object.

Rclone only provides client-side content encryption when operations go through a `crypt` remote; using the underlying provider remote directly does not encrypt content ([rclone crypt documentation](https://rclone.org/crypt/)). Pika/Borg encryption, if the user enables it, protects the Pika repository but does not protect this separate OS stream.

**Required fix:** either configure and require a tested rclone `crypt` remote or encrypt/authenticate the stream independently (for example, `age` or a comparably supportable format). Verify the configured backend type before first upload, run an integrity check, and include key/config/passphrase escrow and recovery steps. Until then, remove every “encrypted” claim and show an explicit plaintext warning.

### ABW-004 — The “OS clone” omits other Btrfs subvolumes (**High**)

**Locations:** `lib/detect.sh:100-112`, `lib/layer2_btrbk.sh:55-78`, `templates/bare-metal-runbook.txt:162-179`, `templates/cloud-recovery-runbook.txt:177-192`

The generated btrbk config backs up only `volume /` / `subvolume .`, i.e. the currently mounted root subvolume. Detected sibling subvolumes such as `@home`, `@root`, `@srv`, `@log`, or distro-specific paths are merely printed into a template variable; they are not added to btrbk.

Btrfs snapshots are not recursive: nested subvolumes are barriers and their contents do not appear in the snapshot ([Btrfs subvolume documentation](https://btrfs.readthedocs.io/en/stable/btrfs-subvolume.html)). Sibling subvolumes mounted into the root tree are likewise outside the root subvolume. The recovery runbooks then create several subvolumes empty, which silently loses any data that lived in them. Pika may cover one user's home, but it does not cover `/root`, `/srv`, other users, or arbitrary application subvolumes.

Btrbk itself recommends operating from a top-level (`subvolid=5`) mount and naming the subvolumes to protect; its `subvolume .` layout is explicitly described as not recommended ([btrbk FAQ](https://github.com/digint/btrbk/blob/master/doc/FAQ.md)).

**Required fix:** inventory actual mount-to-subvolume mappings and let the user choose the scope. Mount subvolid 5 at a dedicated path, configure every required subvolume explicitly, and test a receive of each. Alternatively narrow the product promise to “root-subvolume backup” and clearly enumerate exclusions before setup and in every runbook.

### ABW-005 — The weekly cloud job can copy an inconsistent Borg repository (**High**)

**Locations:** `templates/pika-cloud-sync.service:6-12`, `templates/pika-cloud-sync.timer:4-7`

The weekly service recursively runs `rclone copy` over the live `Personal` directory. It does not coordinate with Pika/Borg, so it can read repository files while an archive is being created, pruned, or compacted. It also uses `copy`, which retains remote-only files; the result is not guaranteed to be an identical repository image after local compaction or deletion.

Borg's documentation says a copied/synchronized repository must be copied while no backup is running and points to `borg with-lock`; it also recommends two independent repositories over cloning one repository ([Borg FAQ](https://borgbackup.readthedocs.io/en/stable/faq.html), [borg with-lock](https://borgbackup.readthedocs.io/en/stable/usage/lock.html)).

**Required fix:** prefer a real independent offsite Borg repository written by Borg/Pika. If repository cloning remains a deliberate fallback, identify the exact repo, acquire its Borg lock, copy from a stable read-only Btrfs snapshot, use semantics that create a verified exact image, and document stale-lock/repository-ID recovery. Never sweep the whole `Personal` parent directory as a repository.

### ABW-006 — Recovery ignores the detected layout and may leave the system unbootable (**High**)

**Locations:** `lib/detect.sh:76-112`, `templates/bare-metal-runbook.txt:162-222`, `templates/cloud-recovery-runbook.txt:177-232`

Both disaster-recovery templates always create and mount `@`, `@home`, `@log`, `@cache`, `@tmp`, `@srv`, and `@root`, regardless of `ROOT_SUBVOL`, `SUBVOL_LAYOUT`, and the original `fstab`. A machine using `@rootfs`, `@var_log`, no `@home`, an extra `@games`, or another valid layout will get missing mounts or unrelated empty subvolumes.

EFI placement is also guessed by attempting `/boot` first and `/efi` only if mounting fails. Mounting a FAT filesystem at `/boot` usually succeeds even when the original ESP was `/efi`, so the fallback cannot discover the intended location. `DETECTED_EFI_MOUNT` is collected but never rendered into the templates.

Finally, when the ESP is mounted at `/boot`, the Btrfs root clone does not contain that filesystem. The runbook formats a new blank ESP, then runs `mkinitcpio` and bootloader install commands, but does not reliably restore/reinstall kernel images, microcode, loader entries, UKIs, Secure Boot signatures/keys, or a separate XBOOTLDR partition. A fresh `bootctl install` does not reconstruct all of those artifacts.

**Required fix:** generate recovery steps from an explicit machine profile containing the real root subvolume, every `fstab` mount, ESP/XBOOTLDR mountpoints, bootloader mode, kernels, UKIs, encryption, RAID/LVM, and Secure Boot state. If a profile is unsupported, refuse to claim bare-metal recovery. Exercise each supported profile in a VM from blank disks through successful boot.

### ABW-007 — Cloud recovery uses a nonexistent subvolume name (**High**)

**Locations:** `templates/os-cloud-backup.sh:21-27`, `templates/cloud-recovery-runbook.txt:138-173`

The archive filename is `Cloud_Archive.btrfs.zst`, but `btrfs send` preserves the sent subvolume's name in its stream. After `btrfs receive`, the created path is therefore based on the selected btrbk snapshot name, not `Cloud_Archive` ([Btrfs send stream format](https://btrfs.readthedocs.io/en/latest/dev/dev-send-stream.html)).

The runbook tells the operator to identify `<RECEIVED_NAME>`, then ignores it and runs:

```bash
btrfs subvolume snapshot /mnt/new_os/Cloud_Archive /mnt/new_os/@
btrfs subvolume delete /mnt/new_os/Cloud_Archive
```

Those commands fail for the archive this project creates.

**Required fix:** capture the received path deterministically (for example, parse `btrfs receive -v` output or compare subvolume inventories before/after), validate it as a read-only received subvolume, and use the captured variable in every subsequent command. Test the exact generated archive/restore pair.

### ABW-008 — Borg home restore extracts into the wrong directory (**High**)

**Locations:** `templates/bare-metal-runbook.txt:299-312`, `templates/cloud-recovery-runbook.txt:311-323`

The runbooks `cd` into `/home/<user>` (or `/mnt/target/home/<user>`) and then extract the entire archive. Pika archives paths such as `home/<user>/...`; Borg always extracts archive paths beneath the current working directory. The result is `/home/<user>/home/<user>/...`, not the restored home. Borg explicitly documents current-directory extraction and `--strip-components` ([Borg extract documentation](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)); the ArchWiki calls out this exact home-under-home failure mode ([ArchWiki Borg backup](https://wiki.archlinux.org/title/Borg_backup)).

**Required fix:** inspect an archive with `borg list`, dry-run extraction, then either extract from `/mnt/target` so `home/<user>` lands correctly or select the home path and use a verified `--strip-components` count. Preserve numeric IDs/ACLs/xattrs deliberately and do not blindly `chown -R` data that may legitimately have other ownership.

### ABW-009 — Rollback cannot find an `@snapshots` layout configured by the wizard (**High**)

**Locations:** `lib/layer1_snapper.sh:64-114`, `templates/rollback-runbook.txt:121-137`, `templates/rollback-runbook.txt:253-282`

Layer 1 explicitly detects and mounts top-level subvolumes named `@snapshots` or `@.snapshots` at `/.snapshots`. From a top-level Btrfs mount, those paths are `/mnt/btrfs-top/@snapshots` or `/mnt/btrfs-top/@.snapshots`.

The rollback runbook only checks `/mnt/btrfs-top/.snapshots/...` and `/mnt/btrfs-top/@/.snapshots/...`. Neither path addresses the supported top-level names, so the recovery instructions fail precisely on one of the layouts setup is designed to preserve. The runbook also hard-codes the live root name `@` rather than using the detected root subvolume.

**Required fix:** detect and persist the filesystem-root path of the Snapper subvolume and root subvolume, then render exact paths. Before destructive renames, require commands that verify subvolume IDs, snapshot read-only state, expected UUID, and an unused destination name. Prefer a generated helper with a `--check` mode over copy/pasted path guesses.

### ABW-010 — Validation can report false health (**High**)

**Locations:** `lib/validate.sh:86-125`, `lib/validate.sh:139-169`, `lib/validate.sh:175-232`, `lib/validate.sh:262-326`

The dashboard mostly verifies packages, config files, timers, and directories. It does **not** establish core backup invariants:

- Layer 2 does not verify that `BACKUP_MOUNT` is a mountpoint backed by the expected UUID, that `btrbk.conf` parses, that the service override contains the expected mount/priority, that any target snapshot exists, or that the last run succeeded and is recent.
- Layer 3 does not identify the configured Pika repository, schedule, latest successful archive, encryption mode, or `borg check` result. A JSON file plus a `Personal` directory can pass.
- Layer 4 does not verify the rclone remote, encryption backend, service file, enabled/running timer, latest successful upload, remote object integrity, or Borg-copy consistency. A failed `systemctl --user enable` is only warned about during setup, yet validation can still mark Layer 4 OK because the timer file exists.
- Cross-layer validation treats any one `*Runbook*.txt` file as sufficient and never checks unresolved placeholders or whether the matching runbook exists.
- Directory existence is accepted where device identity and mount state are required.

This conflicts with README claims that validation checks Borg initialization, rclone, bootloader integration, unit overrides, priorities, isolation, and all runbooks.

**Required fix:** define machine-checkable invariants per layer, including freshness thresholds and expected device identity. Parse native tools (`btrbk -n`, `btrbk list`, `borg info/check`, `systemctl show`, `rclone config redacted`/`lsjson`, `findmnt --json`). Distinguish **configured**, **last backup successful**, **fresh**, **integrity checked**, and **restore tested** instead of collapsing them into “OK”.

### ABW-011 — Setup/uninstall do not track ownership of system state (**High**)

**Locations:** `lib/layer1_snapper.sh:23-24`, `lib/layer1_snapper.sh:119-196`, `lib/layer2_btrbk.sh:55-87`, `lib/uninstall.sh:36-79`

If Snapper or btrbk is already configured, setup backs up and then replaces the configuration wholesale. There is no manifest recording whether a file, service enablement, or config token predated the wizard. Uninstall subsequently disables shared timers and deletes `/etc/snapper/configs/root`, `btrbk.conf`, and the drop-in instead of restoring the saved versions.

The uninstaller also applies this GNU-sed expression to the entire `/etc/conf.d/snapper` file:

```bash
sed -i 's/\broot\b//g; ...' /etc/conf.d/snapper
```

It is not scoped to `SNAPPER_CONFIGS=`. It can remove the word `root` from comments and unrelated values such as `/root/...`, corrupting user configuration. Conversely, the wizard-created backup-drive `fstab` entry is not removed or restored, so “All wizard configurations have been removed” is also false.

**Required fix:** maintain a root-owned state manifest with original hashes, backup paths, created-vs-adopted state, service enablement state, and exact managed blocks. Refuse to overwrite unknown configs without an explicit import/replace choice. Uninstall should restore what existed, remove only manifest-owned resources, edit only the parsed `SNAPPER_CONFIGS` assignment, and reconcile the exact managed `fstab` record.

### ABW-012 — GRUB and Limine integrations are incomplete (**High**)

**Locations:** `lib/packages.sh:95-102`, `lib/layer1_snapper.sh:216-245`, `lib/validate.sh:25-84`

For GRUB, the wizard enables `grub-btrfsd` but installs only `grub-btrfs`. On current Arch, `inotify-tools` is an optional package specifically required by the daemon ([Arch package metadata](https://archlinux.org/packages/extra/any/grub-btrfs/)); on a clean machine the service can therefore fail.

For Limine, setup installs `limine-snapper-sync` and immediately tells the user integration is active. It never runs the tool's own check, handles `/etc/default/limine`, installs the applicable mkinitcpio/dracut companion, or enables `limine-snapper-sync.service`. Current Arch guidance explicitly requires testing the command and enabling the service ([ArchWiki Limine](https://wiki.archlinux.org/title/Limine)). The package also lists `inotify-tools` as optional for monitoring.

Validation checks neither integration, so these omissions can be hidden behind a Layer 1 “OK”.

**Required fix:** install runtime requirements for the chosen integration, configure its actual snapshot/ESP paths, enable and assert the correct service, generate/rebuild the boot menu, and verify a newly created test snapshot appears in the integration output. Report unsupported boot configurations rather than success.

### ABW-013 — Dry-run is not reliably dry (**High**)

**Locations:** `wizard.sh:34-62`, `wizard.sh:317-329`, `wizard.sh:500-560`, `lib/common.sh:148-155`, `lib/packages.sh:143-149`

There are three independent failures:

1. `ensure_dialog` runs before the dry-run branch and may execute `pacman -S dialog`. A root dry-run also creates/chowns `/var/log/arch-backup-wizard.log`.
2. For an unformatted target, `_format_backup_drive` simulates formatting but returns with the original raw device. `BACKUP_UUID=$(blkid ...)` then fails under `set -e`, aborting the simulation before its preview.
3. Modes are not mutually exclusive. `--dry-run --uninstall` sets both flags; `require_root` allows dry-run through, and `main` executes the real uninstaller before it reaches the simulation branch. The confirmation dialog says uninstall, but the `--dry-run` contract is still violated and non-root execution can delete user-owned cloud scripts and shell hooks.

**Required fix:** parse a single exclusive mode (`setup`, `validate`, `simulate`, `uninstall`) and reject conflicts. Centralize mutation behind helpers that enforce mode. A dry run must not install packages, touch `/var`, mount, partition, or call the uninstaller; use synthetic UUID/mount values for previews. Test it with filesystem/command spies that fail on any mutation.

### ABW-014 — Critical layer failures can be reported as success (**High**)

**Locations:** `wizard.sh:565-599`, `lib/layer1_snapper.sh:119-183`, `lib/layer2_btrbk.sh:55-87`, `lib/layer4_cloud.sh:155-220`

`run_layer` executes every setup function under `set +e` so one layer cannot abort the wizard. The documented contract therefore requires every important command in every layer to check and propagate its own status. Several do not:

- writing the Snapper and btrbk configuration files is followed by a success log without checking the redirection/`cat` result;
- rendering, chmodding, and chowning cloud scripts and systemd units is unchecked;
- user `systemctl daemon-reload` failure is discarded, and timer enablement failure is reduced to a warning;
- the functions continue running, so a later successful `log_success`, dialog, or `return 0` overwrites the failed command's status.

`run_layer` can consequently treat an incomplete layer as successful. Runbooks are generated based on selected layers rather than successfully configured layers, and the shallow validator may not detect the missing/broken content.

**Required fix:** do not use ambient shell error mode as the layer result. Wrap every mutating action in a checked helper, return/accumulate a structured failure explicitly, and track `SELECTED`, `CONFIGURED`, and `VERIFIED` layers separately. Add fault-injection tests for unwritable config paths, failed template rendering, failed ownership changes, and unavailable user systemd sessions.

### ABW-015 — The OS cloud archive can be stale, raced, and overwritten (**Medium**)

**Locations:** `templates/os-clone-nag.sh:13-45`, `templates/os-cloud-backup.sh:6-29`

The cloud script chooses the “latest” entry using directory mtime. A Btrfs subvolume root directory's mtime is not a reliable backup creation timestamp; newer snapshots can retain older root-directory mtimes, and any non-subvolume entry can win. The script does not verify that the selected path is a read-only Btrfs subvolume.

The `pgrep` check in the nag script is not a lock: two terminals can race between the check and `zenity`, launching two jobs. Both jobs use the same local archive path; either process's EXIT trap can delete the other's file during compression/upload.

Every successful upload also uses the fixed name `Cloud_Archive.btrfs.zst`. On providers without object versioning, each run replaces the prior OS restore point. A bad/corrupt newest snapshot can therefore eliminate the last known-good offsite image.

**Required fix:** select from parsed btrbk metadata or validated read-only subvolumes, use `flock` across the whole operation, create a unique timestamped temporary/archive name, upload atomically, retain multiple generations, and verify the remote checksum/size before marking the period successful. Keep the final `read` prompt from changing the backup's success status.

### ABW-016 — Pika instructions do not match the repository state (**Medium**)

**Locations:** `lib/layer3_pika.sh:43-67`, `lib/layer3_pika.sh:126-173`

Setup creates an empty directory at `Personal/backup-<host>-<user>` and explicitly defers Borg initialization. It then tells the user to browse to that path and says “Pika will detect the existing Borg repository.” There is no repository for Pika to detect.

Current Pika instructions for a new local backup ask for a **repository base folder** and a repository name, after which Pika creates the repository ([Pika removable-drive setup](https://help.gnome.org/pika-backup/setup-drive.html)). Pointing Pika at the pre-created final path can lead to a nested repository whose location no longer matches the runbooks. Merely finding `backup.json` later does not prove the requested repository or hourly schedule was configured, yet the dialog says hourly backups are active.

**Required fix:** follow Pika's current create-new flow: pass `Personal` as the base, specify/verify the intended repository name, and validate the actual URL and schedule in `backup.json`. Alternatively initialize a supported encrypted Borg repository first and use Pika's add-existing flow with accurate instructions. Verify the first archive before declaring success.

### ABW-017 — Mount point and `fstab` inputs are insufficiently validated (**Medium**)

**Locations:** `wizard.sh:303-314`, `wizard.sh:355-380`, `lib/layer4_cloud.sh:122-151`

The mount input accepts empty, relative, root/system paths, tabs/newlines, existing nonempty directories, symlinks, and paths already backed by another device. Only literal spaces are converted to `\040` before appending to `fstab`; other whitespace/backslashes are not escaped. A malformed or surprising path can break `fstab`, mount over user data, or make later cleanup target the wrong directory. Cloud folder inputs are similarly not restricted before being embedded into shell/systemd configuration.

**Required fix:** require a canonical absolute path outside protected system locations, reject control characters and symlinks, check existing contents and mount ancestry, escape with an `fstab`-aware routine, and validate the generated file with `findmnt --verify --tab-file` before replacing `/etc/fstab`. Validate rclone paths and generated units with native parsers before installation.

### ABW-018 — Validation has avoidable mode/UX failures (**Medium**)

**Locations:** `lib/validate.sh:9-21`, `lib/runbooks.sh:15-26`, `lib/validate.sh:262-291`, `README.md:111-122`

`--validate` calls `detect_dialog`; if neither dialog nor whiptail is installed, `detect_dialog` calls `die`, even though the dashboard is printed to stdout and only displays a dialog when stdout is a TTY. This prevents useful headless/SSH/CI validation.

For a Snapper-only setup, `generate_runbooks` changes the global empty `BACKUP_MOUNT` to `~/Backup`. The following validator sees a nonempty mount variable and requires an `fstab` entry even though Layer 1 needs no backup drive. Thus a successful Layer 1-only setup can end in an irrelevant failure.

The README additionally says XDG autostart is accepted for the nag script, but validation only checks the shell rc file.

**Required fix:** make terminal output the default validation backend and dialogs optional. Only run cross-layer drive checks when a selected layer requires that drive. Keep runbook output location separate from backup-device state. Implement or remove the documented autostart check.

### ABW-019 — Layer 4 creates Pika jobs when Layer 3 is absent (**Medium**)

**Locations:** `wizard.sh:172-190`, `lib/layer4_cloud.sh:122-220`, `templates/pika-cloud-sync.service:12`

Layer 4 is allowed with Layer 2 alone, yet it always asks for a Pika folder, writes `pika-cloud-sync.service`, and enables its timer. On a Layer 2 + Layer 4 setup, the job sweeps the generic `Personal` directory even though no Pika repository exists. It can also upload the transient OS archive if the weekly timer overlaps the manual OS job.

**Required fix:** generate the Pika cloud job only when Layer 3 is selected and only for the verified Borg repository path. Model OS and home offsite pipelines independently in dependencies, setup summaries, validation, and uninstall.

### ABW-020 — CLI and documentation drift (**Low**)

**Locations:** `wizard.sh:5`, `wizard.sh:34-92`, `README.md:52-64`, `README.md:111-122`, `lib/packages.sh:45-54`

- `--verbose` / `-v` is documented in the script banner and README but is not parsed; it exits as an unknown option.
- The README claims validation checks bootloader integration, unit overrides/priorities, Borg initialization, rclone, Deep Storage isolation, and all three runbooks; the implementation does not.
- The README says validation recognizes XDG autostart; it does not.
- The AUR-helper error tells vanilla Arch users to run `sudo pacman -S paru`, but `paru` is an AUR package, not an official repository package ([AUR package page](https://aur.archlinux.org/packages/paru)).
- The welcome screen says Btrfs root is universally required, while dependency checking only requires it for Layers 1 and 2.

**Required fix:** derive `--help` and README option text from one source, add CLI contract tests, and phrase validation output according to what is actually proven.

### ABW-021 — Quality gates do not exercise backup behavior (**Medium**)

**Locations:** `Makefile:1-4`, `.github/workflows/lint.yml:1-11`, `README.md:201-219`

The only automated gate is ShellCheck. The workflow explicitly ignores `templates`, even though two templates become executable shell scripts and two become systemd units. There are no tests for drive filtering, mode conflicts, template escaping, idempotency, uninstall ownership, btrbk parsing, systemd units, or any restore path. The CI action is also referenced as mutable `@master`, reducing reproducibility.

This is especially risky because most severe defects above are valid Bash and cannot be found by a linter.

**Required fix:** add fixture-driven Bash tests (for example, Bats) with mocked `lsblk`, `findmnt`, `blkid`, `systemctl`, and `rclone`; render templates with hostile/space-containing values and validate them with `bash -n`, ShellCheck, and `systemd-analyze verify`; pin CI actions to immutable revisions. Add a privileged disposable-VM suite that performs setup, creates known data across supported subvolumes, runs backups, destroys the primary virtual disk, follows an automated equivalent of each runbook, and verifies data plus successful boot.

## Recommended remediation order

1. **Fail closed on storage targets:** fix ABW-001, ABW-002, and ABW-017 before allowing any partition/format path.
2. **Correct the security promise:** fix ABW-003 and create recoverable encryption-key handling.
3. **Define what is actually backed up:** fix ABW-004, then make runbooks consume the same generated machine profile.
4. **Make restore executable:** fix ABW-006 through ABW-009 and prove them in blank-disk VMs.
5. **Make offsite state consistent:** fix ABW-005 and ABW-015; keep OS and Pika pipelines separate (ABW-019).
6. **Replace presence checks with backup invariants:** fix ABW-010 and ABW-018.
7. **Track ownership, reversibility, and explicit failure state:** fix ABW-011, ABW-013, and ABW-014.
8. **Finish integrations and guard regressions:** fix ABW-012, ABW-016, ABW-020, and ABW-021.

## Positive observations worth preserving

- Shell paths in the current generated scripts are generally quoted, and both generated Bash scripts use `set -euo pipefail`.
- Destructive formatting uses a default-No confirmation, even though stronger device identity checks are still required.
- Layer setup is modular and has a documented return-value contract.
- The btrbk service uses `RequiresMountsFor`, `Nice=19`, and idle I/O scheduling.
- Files are backed up before overwrite, providing raw material for a future ownership-aware rollback mechanism.
- The Pika cloud command was changed from `rclone sync` to non-deleting `copy`, which reduces accidental remote deletion even though it does not solve Borg repository consistency.
- Runbook generation is centralized, making it feasible to replace hard-coded layouts with one validated machine profile.

## Verification performed and limitations

- `bash -n wizard.sh lib/*.sh templates/*.sh` — **passed**; no Bash syntax errors.
- Template placeholder inventory — every current placeholder has a corresponding setup/export path, although dry-run previews can render empty cloud values.
- Manual read-only trace of setup, dry-run, validate, uninstall, generated service/script, and all three recovery workflows.
- Cross-checks against current primary/authoritative documentation for Btrfs, btrbk, Borg, rclone, Pika Backup, Arch package metadata, and ArchWiki integration guidance.
- `make check` — **passed** with ShellCheck 0.11.0 (`shellcheck -x wizard.sh lib/*.sh`). As noted above, this target does not lint the generated shell-script templates or validate the systemd templates.
- No destructive commands, mounts, package installations, systemd changes, or live backup/restore operations were performed. Full behavior still needs verification in an Arch VM with disposable disks.

## Release recommendation

**Do not release or recommend this as “production-grade” until ABW-001 through ABW-014 are resolved and an end-to-end bare-metal restore has passed on every advertised bootloader/layout combination.** Lower-severity items can follow, but drive-selection safety, mount identity, encryption, backup scope, consistent Borg replication, recovery correctness, explicit error propagation, and meaningful health reporting are foundational rather than optional hardening.
