# In-VM End-to-End Test Suite

This directory contains the automated end-to-end integration and verification harness for the **Arch Backup Wizard**, running inside an isolated Arch Linux QEMU virtual machine.

## Structure

- **`backup.qcow2`**: Pre-configured Arch Linux virtual disk formatted with BTRFS subvolumes (`@`, `@home`, `@log`, `@cache`, `@tmp`, `@srv`, `@root`, `@/.snapshots`), GRUB EFI bootloader, and all necessary tools pre-installed (`snapper`, `btrbk`, `borg`, `rclone`, `age`, `dialog`, `shellcheck`, etc.).
- **`backup-drive.qcow2`**: Secondary 10 GB virtual drive provisioned with BTRFS and mounted at `/mnt/backup`, simulating an external backup drive.
- **`Arch-Linux-x86_64-cloudimg.qcow2`**: Base Arch Linux cloud-init image used for bootstrapping and out-of-band code synchronization.
- **`cidata/`**: Cloud-init seed configurations and automated test scripts:
  - **`run_vm_tests.sh`**: The full 28-test verification suite executing as non-root user `arch` with `sudo`.
  - **`setup_btrfs.sh`**: Partitioning, subvolume formatting, package installation, and synchronization script.
  - **`user-data` / `meta-data`**: Cloud-init configuration files.
- **`run.sh`**: Test runner script.

## Usage

### Run Tests Directly
```bash
./run.sh
```
Boots the pre-provisioned VM, executes the complete 28-stage test suite, and outputs the results summary.

### Sync Local Changes & Run Tests
```bash
./run.sh --sync
```
Syncs the current workspace code from the repository into the VM image via cloud-init before running the verification suite.
