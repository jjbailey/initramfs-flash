# initramfs-flash

Build a small, PXE/iPXE-bootable Linux environment that downloads a disk image
and writes it directly to a machine's target disk.

## Purpose

This Makefile automates the creation and deployment of a customized minimal
initramfs and a matching kernel image for PXE/TFTP deployment. The resulting
BusyBox-based environment brings up networking, downloads a disk image, and
flashes it to a block device.

## Why use this project?

This project is useful when the same operating-system image must be installed
repeatedly on bare-metal or virtual machines, especially when the machines do
not yet have a usable operating system. A normal installer or rescue image
usually requires interactive choices and a larger userland. This project
instead provides one small, repeatable boot path:

1. Boot a kernel and initramfs over PXE/iPXE.
2. Discover a usable network interface with DHCP.
3. Download a prepared disk image from an HTTP(S) URL.
4. Write it to the selected disk and reboot.

The initramfs includes drivers and firmware from the build host's running
kernel, along with common physical, virtual, and RAID storage/network drivers.
That makes it practical for provisioning a mixed fleet while keeping the
deployment logic in one auditable shell script. It is a disk-imaging tool, not
a general-purpose installer: the `img=` URL and target `dev=` device must be
chosen carefully because flashing overwrites the target device.

## Configuration

Variables can be overridden when running make:

- `DISTRO`: A label for the image being built (**required**, e.g.
  `ubuntu-24.04`). It sets the output filename
  (`build/$(DISTRO).initrd`) and TFTP subdirectory; it does not select or
  build a distribution image.
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
- **Module & Firmware Inclusion:** Copies network, storage, virtio, and RAID
  modules plus dependency metadata and all available firmware from the
  currently-running kernel's host system. The build expects
  `/lib/modules/$(uname -r)` to exist.
- **Packaging:** Packs the root filesystem with `cpio` and `gzip` into
  `build/$(DISTRO).initrd`.

### 3. Deployment/Install to TFTP Boot Directory

- **Backup + Copy:** On `make install`, the Makefile backs up previous images
  (by appending `~`), then installs the new kernel and `build/$(DISTRO).initrd`
  to `$(TFTPBOOT)/$(DISTRO)-flash/`. If no prior images exist, the backup step
  is silently skipped.
- **iPXE Menu:** Also generates
  `$(TFTPBOOT)/$(DISTRO)-flash/ipxe.menu` with a sample iPXE boot stanza. The
  stanza uses `http://10.0.0.6/$(DISTRO)-flash` and expects the disk image at
  `$(DISTRO).raw.gz`; edit the Makefile or generated menu for another server,
  protocol, or image name.
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
- **Driver & Firmware Coverage:** Inclusion of common network, storage,
  virtio, RAID, and VMware drivers, plus all firmware available on the build
  host. This is broad coverage, not a guarantee that every adapter is
  supported.
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

   _Copies the running host kernel and builds the initramfs
   (`build/ubuntu-24.04.initrd`)._

2. **Deploy to PXE/TFTP directory:**

   ```bash
   make install DISTRO=ubuntu-24.04
   ```

   _Backs up existing tftpboot images (appends `~`), then installs the
   newly built kernel and initrd, and writes a sample `ipxe.menu`._

3. **Clean build artifacts:**

   ```bash
   make clean
   ```

   _Removes rootfs, `vmlinuz-_`, and any `build/_.initrd`. Keeps the
   cached BusyBox download._

   ```bash
   make distclean
   ```

   _Full clean including the cached BusyBox binary._

4. **Copy kernel modules only (without rebuilding everything):**

   ```bash
   make modules DISTRO=ubuntu-24.04
   ```

   _Copies kernel modules and firmware for the running host kernel into the
   rootfs. Run the normal build afterward to package the updated rootfs._

5. **Show help:**

   ```bash
   make help
   ```

   _Displays available targets and configurable variables._

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
   - Downloads and streams the specified disk image to the target disk
     (configurable via `dev=`; defaults to `/dev/sda`), then reboots. URLs
     ending in `.gz` are decompressed while streaming.

---

## Summary

This Makefile provides an automated workflow for generating and deploying a
PXE-bootable disk-imaging environment matched to the current host kernel. It
enables consistent, rapid OS deployment in datacenter or lab environments,
while keeping the boot environment small and the provisioning behavior easy to
inspect.
