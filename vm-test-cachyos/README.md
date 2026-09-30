# In-VM End-to-End Test Suite

This directory contains the automated end-to-end integration and verification harness for the **Arch Backup Wizard**, running inside an isolated CachyOS QEMU virtual machine.

## Structure

- **`backup.qcow2`**: Pre-configured CachyOS virtual disk formatted with BTRFS subvolumes (`@`, `@home`, `@log`, `@cache`, `@tmp`, `@srv`, `@root`, `@/.snapshots`), Limine EFI bootloader, and all necessary tools pre-installed (`snapper`, `btrbk`, `borg`, `rclone`, `age`, `dialog`, `shellcheck`, etc.).
- **`backup-drive.qcow2`**: Secondary 10 GB virtual drive provisioned with BTRFS and mounted at `/mnt/backup`, simulating an external backup drive.
- **`Arch-Linux-x86_64-cloudimg.qcow2`**: Base cloud-init image used for bootstrapping and out-of-band code synchronization.
- **`cidata/`**: Cloud-init seed configurations and automated test scripts:
  - **`run_vm_tests.sh`**: The full 30-test verification suite executing as non-root user `arch` with `sudo`.
  - **`setup_btrfs.sh`**: Partitioning, subvolume formatting, package installation, and synchronization script.
  - **`user-data` / `meta-data`**: Cloud-init configuration files.
- **`test.sh`**: Executes the 30-stage automated test suite in ephemeral QEMU `-snapshot` mode (base disks are never modified).
- **`interactive.sh`**: Launches an interactive manual terminal console session with the real `dialog` TUI (supports `--persist`).
- **`sync.sh`**: Syncs current repository code into the base VM disk image.
- **`run.sh`**: Top-level dispatcher for all operations.

## Usage

### Run Automated Tests (Snapshot Mode)
```bash
./test.sh
# or: ./run.sh
```
Boots the VM in ephemeral `-snapshot` mode, triggers the automated runner, executes the complete 30-stage test suite, and outputs the results summary. The base disk images remain 100% unmodified.

### Sync Local Changes & Run Tests
```bash
./run.sh --sync
```
Syncs the current workspace code from the repository into the VM image via cloud-init, then executes the automated test suite.

### Interactive Manual Testing
```bash
./interactive.sh
# or: ./run.sh --interactive
```
Attaches the VM serial console directly to your terminal. Launches an interactive shell where you can run `sudo ./wizard.sh` with the real `dialog` TUI without automated test interference. By default runs with `-snapshot`; pass `--persist` to save manual modifications to the disk.
