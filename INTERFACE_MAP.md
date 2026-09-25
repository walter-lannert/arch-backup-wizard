# Arch Backup Wizard — Global Interface & State Manifest

This manifest documents the cross-module contracts, shared state, exported variables,
and system resource footprints across the `arch-backup-wizard` codebase.

---

## 1. Global State & Shared Variables

| Variable | Defined In | Primary Consumers | Contract / Semantics |
|---|---|---|---|
| `WIZARD_DIR` | `wizard.sh` | `lib/*.sh`, `templates/*` | Absolute directory of the wizard root. |
| `WIZARD_VERSION` | `wizard.sh` | `lib/ui.sh`, `templates/*` | Version string (e.g. `0.1.0`). |
| `DRY_RUN` | `wizard.sh` | `lib/common.sh`, `lib/packages.sh`, `lib/runbooks.sh` | Boolean (`true`/`false`). When `true`, commands are logged/simulated without system mutation. |
| `LOG_FILE` | `wizard.sh`, `lib/common.sh` | All modules | Path to wizard log (`/var/log/arch-backup-wizard.log` or `/tmp/...`). |
| `SELECTED_LAYERS` | `wizard.sh`, `lib/common.sh` | `lib/common.sh`, `lib/layer4_cloud.sh`, `lib/runbooks.sh`, `lib/validate.sh` | Array of chosen layer IDs (e.g. `("1" "2" "3" "4" "5")`). |
| `BACKUP_MOUNT` | `wizard.sh` | `lib/layer2_btrbk.sh`, `lib/layer3_pika.sh`, `lib/layer4_cloud.sh`, `lib/layer5_deep_storage.sh`, `lib/runbooks.sh`, `lib/validate.sh`, `lib/uninstall.sh` | Mount point of the backup filesystem (e.g. `/home/walter/Backup`). |
| `BACKUP_DEV` | `wizard.sh` | `wizard.sh`, `lib/validate.sh` | Underlying block device (e.g. `/dev/sda1`). |
| `BACKUP_UUID` | `wizard.sh`, `lib/runbooks.sh` | `lib/runbooks.sh`, `lib/validate.sh` | Filesystem UUID of the backup partition. |
| `SYSTEMD_BACKUP_MOUNT`| `wizard.sh`, `lib/layer4_cloud.sh` | Templates / systemd escaping | Space-escaped path for systemd unit dependencies (`\x20`). |
| `DETECTED_USER` | `lib/detect.sh` | All layers, `lib/common.sh`, `wizard.sh` | Target non-root user (e.g. `walter`). |
| `DETECTED_HOME` | `lib/detect.sh` | `lib/layer3_pika.sh`, `lib/layer4_cloud.sh`, `lib/layer5_deep_storage.sh` | Target user home directory (e.g. `/home/walter`). |
| `DETECTED_DISTRO` | `lib/detect.sh` | `lib/detect.sh`, `lib/layer4_cloud.sh`, `lib/runbooks.sh` | Distro name (e.g. `cachyos`, `arch`). |
| `DETECTED_AUR_HELPER` | `lib/detect.sh` | `lib/packages.sh` | Detected AUR package manager (`paru`, `yay`, or empty). |
| `DETECTED_BOOTLOADER` | `lib/detect.sh` | `lib/layer1_snapper.sh`, `lib/packages.sh`, `lib/runbooks.sh`, `lib/validate.sh` | Bootloader (`systemd-boot`, `grub`, `limine`, `refind`, `none`). |
| `DETECTED_ROOT_DEV` | `lib/detect.sh` | `lib/layer1_snapper.sh`, `lib/layer2_btrbk.sh`, `lib/runbooks.sh`, `lib/validate.sh` | Root block device (e.g. `/dev/nvme2n1p2`). |
| `DETECTED_ROOT_FS` | `lib/detect.sh` | `wizard.sh`, `lib/validate.sh` | Filesystem type of root (`btrfs`, `ext4`, etc.). |
| `DETECTED_ROOT_SUBVOL`| `lib/detect.sh` | `lib/layer1_snapper.sh`, `lib/layer2_btrbk.sh`, `lib/runbooks.sh`, `lib/validate.sh` | Top-level subvolume mounted at `/` (typically `@`). |
| `DETECTED_ROOT_UUID` | `lib/detect.sh` | `lib/layer1_snapper.sh`, `lib/runbooks.sh` | Filesystem UUID of root partition. |
| `DETECTED_EFI_MOUNT` | `lib/detect.sh` | `lib/runbooks.sh` | Mount point of ESP (e.g. `/boot` or `/efi`). |
| `DETECTED_EFI_UUID` | `lib/detect.sh` | `lib/runbooks.sh` | UUID of EFI System Partition. |
| `DETECTED_SUBVOL_MOUNTS`| `lib/detect.sh` | `lib/layer2_btrbk.sh`, `lib/runbooks.sh` | Space-delimited subvolume paths mounted on root (e.g. `@ @home`). |
| `CLOUD_REMOTE` | `lib/layer4_cloud.sh`, `wizard.sh` | `lib/layer4_cloud.sh`, `lib/runbooks.sh` | Rclone remote name with trailing colon (e.g. `googledrive:`). |
| `CLOUD_OS_DIR` | `lib/layer4_cloud.sh`, `wizard.sh` | `lib/layer4_cloud.sh`, `lib/runbooks.sh` | Cloud directory for OS clones (e.g. `CachyOS_BareMetal_Clones/`). |
| `CLOUD_PIKA_DIR` | `lib/layer4_cloud.sh`, `wizard.sh` | `lib/layer4_cloud.sh`, `lib/runbooks.sh` | Cloud directory for Pika sync (e.g. `CachyOS_Pika_Backup/`). |

---

## 2. Cross-Module Function Call Graph

| Function | Defined In | Sourced / Called By | Return Contract & Notes |
|---|---|---|---|
| `log_info`, `log_warn`, `log_error`, `log_success` | `lib/common.sh` | All modules | Appends formatted message to stderr & `$LOG_FILE`. |
| `die` | `lib/common.sh` | `wizard.sh`, `lib/common.sh` | Logs fatal error, cleans up UI, exits non-zero. Precondition check only. |
| `run_cmd` | `lib/common.sh` | All `lib/layer*.sh`, `lib/packages.sh`, etc. | Executes command with logging, respecting `$DRY_RUN`. |
| `layer_selected <id>` | `lib/common.sh` | `wizard.sh`, `lib/layer4_cloud.sh`, `lib/runbooks.sh`, `lib/validate.sh` | Returns 0 if layer is in `$SELECTED_LAYERS`, 1 otherwise. |
| `record_manifest <path>` | `lib/common.sh` | All layers, `wizard.sh` | Appends file to `/var/lib/arch-backup-wizard/manifest` for clean uninstall. |
| `template_render <src> <dst>` | `lib/common.sh` | `lib/layer2_btrbk.sh`, `lib/layer4_cloud.sh`, `lib/runbooks.sh` | Safely performs placeholder substitution using awk/sed with strict escaping. |
| `run_detection` | `lib/detect.sh` | `wizard.sh` | Probes system hardware, mount points, fstab, and sets all `DETECTED_*` variables. |
| `pkg_install <pkgs...>` | `lib/packages.sh` | All `lib/layer*.sh` | Verifies package presence or installs via pacman/AUR helper. |
| `setup_layer1` | `lib/layer1_snapper.sh` | `wizard.sh` (via `run_layer`) | Configures Snapper for root, sets cleanup limits, enables timers. |
| `setup_layer2` | `lib/layer2_btrbk.sh` | `wizard.sh` (via `run_layer`) | Configures btrbk for daily OS send/receive to `$BACKUP_MOUNT/OS_Backup`. |
| `setup_layer3` | `lib/layer3_pika.sh` | `wizard.sh` (via `run_layer`) | Configures Pika Backup Borg repository at `$BACKUP_MOUNT/Personal`. |
| `setup_layer4` | `lib/layer4_cloud.sh` | `wizard.sh` (via `run_layer`) | Generates cloud backup script, nag script, and systemd sync service/timer. |
| `setup_layer5` | `lib/layer5_deep_storage.sh`| `wizard.sh` (via `run_layer`) | Sets up un-synced deep archive subvolume at `$BACKUP_MOUNT/Deep Storage`. |
| `generate_runbooks` | `lib/runbooks.sh` | `wizard.sh` | Renders customized recovery runbooks into `$BACKUP_MOUNT`. |
| `run_validation` | `lib/validate.sh` | `wizard.sh` (`--validate` or post-setup) | Health-checks all installed layers, verifies subvolumes, units, mounts. |
| `run_uninstall` | `lib/uninstall.sh` | `wizard.sh` (`--uninstall`) | Unwinds wizard configuration based on manifest, disables timers/services. |

---

## 3. System Resource Footprint

### Filesystem Layout & Subvolumes
- Root BTRFS: `/.snapshots` (Snapper), `/.snapshots_btrbk` (btrbk local retention).
- Backup BTRFS (`$BACKUP_MOUNT`):
  - `OS_Backup/` (btrbk target snapshots)
  - `Personal/` (Pika Borg repository)
  - `Deep Storage/` (Excluded from cloud sync)
  - `.pika_sync_snapshot/` (Transient read-only snapshot for rclone sync)
  - `*_Runbook.txt` (Generated recovery runbooks)

### Systemd Units & Timers
- `snapper-cleanup.timer` (every 30m)
- `btrbk.timer` (daily)
- `pika-cloud-sync.service` & `pika-cloud-sync.timer` (nightly offsite sync)
- `pika-cloud-sync-stale-check.service` & `pika-cloud-sync-stale-check.timer` (weekly staleness guard)
- `btrfs-scrub-root.timer` & `btrfs-scrub-backup.timer` (monthly maintenance)

### State Files & Locks
- Manifest: `/var/lib/arch-backup-wizard/manifest`
- Cloud Sync State: `/var/lib/pika-cloud-sync/state`
- Sync Concurrency Lock: `/run/pika-cloud-sync/active`
