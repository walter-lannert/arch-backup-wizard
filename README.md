# Arch Backup Wizard

Interactive TUI wizard that sets up a 5-layer backup architecture for Arch Linux.

---

## Features

- **5 Independent Defense Layers:**
  1. **Snapper** — Instant BTRFS snapshots triggered by pacman (pre/post hooks via `snap-pac`).
  2. **btrbk** — Daily OS clone to a secondary drive via `btrfs send`/`receive`.
  3. **Pika Backup** — Hourly home directory backups powered by Borg.
  4. **Cloud Offsite** — Encrypted offsite backups to Google Drive, OneDrive, Dropbox, or Backblaze B2 via `rclone`.
  5. **Deep Storage** — Local-only archive directory for sensitive files that should never sync offsite.
- **Hardware & Environment Detection:** Auto-detects distribution, bootloader, filesystem layout, drives, and existing configurations.
- **Personalized Recovery Runbooks:** Generates step-by-step restore guides with your system's actual UUIDs, mount paths, and subvolume names.
- **Idempotent:** Safe to run multiple times without duplicating configurations or corrupting existing backups.
- **Gaming-Friendly:** All background maintenance and sync services are throttled to `Nice=19` and `IOSchedulingClass=idle` to eliminate stutter and frame drops.

---

## Supported Systems

### Distros
- CachyOS, EndeavourOS, Manjaro, Garuda Linux, vanilla Arch Linux
- Any Arch-based distribution using `pacman`

### Bootloaders
- **GRUB** (with `grub-btrfs` snapshot boot integration)
- **Limine** (with `limine-snapper-sync`)
- **systemd-boot**

### Requirements
- **BTRFS root filesystem** (required for Layers 1 & 2)
- **Secondary drive** for backup storage (SATA SSD, HDD, or NVMe)
- **Internet connection** for Layer 4 (cloud offsite sync)
- **AUR helper** (`paru` or `yay`) for bootloader integration packages

---

## Quick Start

```bash
git clone https://github.com/youruser/arch-backup-wizard.git
cd arch-backup-wizard
sudo ./wizard.sh
```

---

## Usage

```
sudo ./wizard.sh [OPTIONS]

Options:
  --help, -h       Show help message
  --verbose, -v    Enable verbose logging
  --uninstall      Remove all wizard-created configurations
```

---

## What Gets Installed

| Layer | Packages |
|---|---|
| **1** | `snapper`, `snap-pac`, `grub-btrfs` OR `limine-snapper-sync` (AUR) |
| **2** | `btrbk` |
| **3** | `pika-backup` (includes `borg`) |
| **4** | `rclone`, `pv`, `zstd`, `zenity` |
| **5** | *(none)* |

---

## What Gets Configured

The wizard creates and manages the following configuration files and systemd units:

- `/etc/snapper/configs/root` — Snapper configuration for root subvolume
- `/etc/btrbk/btrbk.conf` — btrbk snapshot retention and send/receive targets
- `/etc/systemd/system/btrbk.service.d/override.conf` — Low-priority resource scheduling override (`Nice=19`, `IOSchedulingClass=idle`)
- `~/.os_cloud_backup.sh` — User cloud upload script for OS snapshots
- `~/.os_clone_nag.sh` — Backup health and staleness notifier
- `~/.config/systemd/user/pika-cloud-sync.{service,timer}` — User systemd timer for background Borg repository cloud syncing
- **Personalized recovery runbooks** on the backup drive

---

## Recovery Runbooks

The wizard generates three tailored runbooks stored on your backup storage drive:

1. **Layer 1 Rollback Runbook** — Manual BTRFS subvolume swap for snapshot rollback when a package update breaks your system.
2. **Bare-Metal Recovery** — Full OS restore from the secondary backup drive in case of primary drive failure.
3. **Cloud Recovery** — Full OS restore from cloud storage when local drives are lost or damaged.

All runbooks are rendered dynamically with your system's actual UUIDs, mount paths, subvolume names, and bootloader commands.

---

## Uninstalling

To clean up wizard-managed configs:

```bash
sudo ./wizard.sh --uninstall
```

> **Note:** The uninstaller removes configuration files and systemd timers created by the wizard, but intentionally preserves your installed packages, backup data, and generated runbooks.

---

## Project Structure

```
arch-backup-wizard/
├── wizard.sh              # Main entry point
├── lib/
│   ├── common.sh          # Logging, helpers, template rendering
│   ├── ui.sh              # dialog/whiptail wrappers
│   ├── detect.sh          # System detection engine
│   ├── packages.sh        # Package installation
│   ├── layer1_snapper.sh  # Snapper setup
│   ├── layer2_btrbk.sh    # btrbk setup
│   ├── layer3_pika.sh     # Pika Backup setup
│   ├── layer4_cloud.sh    # Cloud offsite setup
│   ├── layer5_deep_storage.sh # Deep Storage setup
│   ├── runbooks.sh        # Recovery runbook generator
│   ├── validate.sh        # Post-setup health checks
│   └── uninstall.sh       # Clean removal
└── templates/             # Config and runbook templates
```

---

## License

[MIT](LICENSE)

---

## Credits

Inspired by a battle-tested 5-layer backup architecture running on a CachyOS gaming rig.
