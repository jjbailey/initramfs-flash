# Overview of Makefile

## Purpose

This Makefile automates the creation and deployment of a customized minimal
initramfs and a matching kernel image for PXE/tftpboot deployment. The build
environment produces images that boot a BusyBox-based Linux system capable of
network-based provisioning and disk imaging.

## Configuration

Variables can be overridden when running make:

- `DISTRO`: Target distribution name (**required**, e.g. `ubuntu-24.04`).
  Sets the output filename (`build/$(DISTRO).initrd`) and the tftpboot
  destination directory.
- `BUSYBOX_URL`: URL to download BusyBox binary
  (default: pre-built x86_64-linux-musl)
- `TFTPBOOT`: Path to the tftpboot directory
  (default: `/tftpboot`)

`DISTRO` must be specified on every make invocation — there is no default.

---

## High-Level Workflow

### 1. Kernel Image Preparation

- **Action:** Copies the currently-running kernel
  (`/boot/vmlinuz-$(uname -r)`) to the local directory and names it as
  `vmlinuz-<kernel-version>`.
- **Purpose:** Ensures both kernel and initramfs match and are compatible.

### 2. Initramfs Construction

- **Root FS Setup:** Prepares a directory tree under `build/rootfs/` to be
  used as the new initramfs.
- **BusyBox Installation:** Downloads BusyBox once to `build/busybox`
  (skipped on subsequent builds), hard-links it into the rootfs, and creates
  applet symlinks.
- **Init Script & Overlay:** Copies a custom `init` script plus user-supplied
  overlays (`rootfs_overlay/`).
- **Module & Firmware Inclusion:** Copies kernel modules and their
  dependencies for storage and network drivers, as well as required firmware
  files, all matching the currently-running kernel.
- **Packaging:** Packs the root filesystem with `cpio` and `gzip` into
  `build/$(DISTRO).initrd`.

### 3. Deployment/Install to TFTP Boot Directory

- **Backup + Copy:** On `make install`, the Makefile backs up previous images
  (by appending `~`), then installs the new kernel and `build/$(DISTRO).initrd`
  to `$(TFTPBOOT)/$(DISTRO)-flash/`. If no prior images exist, the backup step
  is silently skipped.
- **iPXE Menu:** Also generates a ready-to-use `$(TFTPBOOT)/$(DISTRO)-flash/ipxe.menu`
  file with a sample iPXE boot stanza for the installed images.
- **Result:** System administrators have up-to-date boot images ready for
  network provisioning.

### 4. Cleanup

- **On `make clean`:** Deletes `build/rootfs/`, local `vmlinuz-*` files, and
  any `build/*.initrd`. Does not require `DISTRO=`. The cached `build/busybox`
  download is preserved. Use `make distclean` to remove it as well.

---

## Key Features

- **Kernel Synchronization:** Always matches the initramfs and kernel versions
  to the host building environment, ensuring driver compatibility.
- **Driver & Firmware Coverage:** Explicit inclusion of standard
  network/storage drivers (e.g., Broadcom, Intel, VMware, Virtio) and
  relevant firmware.
- **Minimalist Userland:** Uses BusyBox for a tiny, single-binary user space,
  with only essential utilities symlinked in.
- **Custom Provisioning Script:** User-provided `init` script automates
  boot-time network setup and disk imaging (see `init`).
- **PXE Server Integration:** Output ready for integration with PXE/TFTP
  infrastructure.
- **Error Handling & Backups:** Checks for missing files and backs up existing
  deploy images before overwriting.

---

## How to Use

1. **Build images:**

    ```bash
    make DISTRO=ubuntu-24.04
    ```

    *Builds both kernel and initramfs (`build/ubuntu-24.04.initrd`).*

2. **Deploy to PXE/TFTP directory:**

    ```bash
    make install DISTRO=ubuntu-24.04
    ```

    *Backs up existing tftpboot images (appends `~`), then installs the
    newly built kernel and initrd, and writes a sample `ipxe.menu`.*

3. **Clean build artifacts:**

    ```bash
    make clean
    ```

    *Removes rootfs, `vmlinuz-*`, and any `build/*.initrd`. Keeps the
    cached BusyBox download.*

    ```bash
    make distclean
    ```

    *Full clean including the cached BusyBox binary.*

4. **Copy kernel modules only (without rebuilding everything):**

    ```bash
    make modules DISTRO=ubuntu-24.04
    ```

    *Copies kernel modules and firmware into the rootfs without a full
    rebuild.*

5. **Show help:**

    ```bash
    make help
    ```

    *Displays available targets and configurable variables.*

---

## What Happens When a Node Boots These Images?

1. The PXE client loads the matching `vmlinuz-<kernel-version>` and
   `$(DISTRO).initrd` initramfs.
2. The BusyBox-based environment starts and runs the custom `init` script:
    - Loads drivers for networking and storage (with dependency and firmware
      support).
    - Brings up network interfaces and fetches a DHCP address.
    - Parses kernel parameters, including the image URL and optional target
      device for provisioning.
    - Downloads and writes the specified disk image to the target disk
      (configurable via `dev=` parameter, defaults to `/dev/sda`), then
      reboots.

---

## Summary

This Makefile provides an automated workflow for generating and deploying
PXE-bootable provisioning environments, matched to the current host kernel.
It enables consistent, rapid OS deployment in datacenter or lab environments,
requiring minimal ongoing maintenance even as the host kernel is updated.
