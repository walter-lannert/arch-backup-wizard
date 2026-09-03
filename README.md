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
- **Secondary drive** for backup storage (SATA SSD, HDD, or NVMe). The wizard accepts existing BTRFS partitions or raw unpartitioned drives, offering automated GPT partitioning and BTRFS formatting with double confirmation.
- **Internet connection** for Layer 4 (cloud offsite sync)
- **AUR helper** (`paru` or `yay`) for bootloader integration packages

---

## Quick Start

```bash
git clone https://github.com/walter-lannert/arch-backup-wizard.git
cd arch-backup-wizard
sudo ./wizard.sh
```

---

## Usage

```
sudo ./wizard.sh [OPTIONS]

Options:
  --help, -h       Show help message
  --validate [L]   Run health checks on backup configuration (all or specified layers: 1,2)
  --dry-run, -d    Simulate wizard actions without making system changes
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

## Bi-Weekly Cloud Backup Reminder (Nag Script)

Layer 4 sets up an intelligent user-space notifier (`~/.os_clone_nag.sh`) that ensures you never fall behind on offsite OS snapshots:

- **Interactive Shell Trigger:** Sourced automatically upon opening an interactive terminal (`.bashrc`, `.zshrc`, or `config.fish`).
- **Bi-Weekly Calendar Period:** Checks whether a cloud backup has been completed for the current period (`YYYY-MM-P1` for days 1–14, `P2` for days 15+).
- **Desktop Environment Guards:** Automatically exits if running outside a graphical session (e.g. SSH logins or virtual TTYs).
- **Concurrency Lock:** Uses process matching to ensure opening multiple terminal tabs simultaneously never spawns duplicate dialogs.
- **Visual Progress:** Prompts with a non-intrusive `zenity` dialog. If you choose **Run Now**, it launches your native terminal emulator (`ptyxis`, `gnome-terminal`, `kitty`, `alacritty`, `konsole`, etc.) showing real-time `btrfs send` throughput and `zstd` compression speeds via `pv`.

### Optional: Desktop Session Autostart (GNOME / KDE / XFCE)

By default, the reminder triggers when you launch an interactive terminal. If you prefer the prompt to appear automatically once when logging into your desktop session, you can hook it via the standard XDG Autostart specification:

```bash
mkdir -p ~/.config/autostart
cat << 'EOF' > ~/.config/autostart/os-clone-nag.desktop
[Desktop Entry]
Type=Application
Name=OS Clone Backup Nag
Comment=Prompts for bi-weekly OS cloud backup
Exec=/bin/bash -c "sleep 10 && exec $HOME/.os_clone_nag.sh"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
```

The validation suite (`./wizard.sh --validate`) automatically recognizes either shell rc startup or XDG Autostart as a valid configuration.

---

## Automated Post-Setup Health Checks

At the end of setup (or when running `--dry-run`), the wizard executes a comprehensive validation suite:

- **Layer 1:** Verifies Snapper configs, ALPM hooks, bootloader integration, and `snapper-cleanup.timer`.
- **Layer 2:** Verifies `btrbk.conf`, `RequiresMountsFor` unit overrides, gaming priorities (`Nice=19`, `idle`), and `btrbk.timer` active state.
- **Layer 3:** Verifies Borg repository initialization and Pika configuration.
- **Layer 4:** Verifies rclone configuration, user sync timers, and shell startup hooks.
- **Layer 5:** Verifies Deep Storage isolation.
- **System Integration:** Verifies `/etc/fstab` backup entries and confirms that all 3 disaster recovery runbooks are present.

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

## Testing & Development

You can test the wizard safely without modifying your primary system:

- **Dry Run Simulation:** Run `sudo ./wizard.sh --dry-run` to simulate system detection, package planning, drive selection, and template rendering without making changes.
- **Headless QEMU / KVM Sandbox:** Developers can launch an isolated virtual machine running the official Arch Linux cloud image with a virtual secondary drive:
  ```bash
  qemu-system-x86_64 -enable-kvm -m 4G -smp 4 -nographic \
    -drive file=Arch-Linux-x86_64-cloudimg.qcow2,format=qcow2,if=virtio,snapshot=on \
    -drive file=backup.qcow2,format=qcow2,if=virtio \
    -net nic,model=virtio -net user -serial mon:stdio
  ```

---

## License

[MIT](LICENSE)

---

## Credits

Inspired by a battle-tested 5-layer backup architecture running on a CachyOS gaming rig.
