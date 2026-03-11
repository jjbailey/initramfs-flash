# High-Level Overview of /init

## Initialization & Logging

- Defines a `notice()` helper function to print highlighted status messages.
- Prints that initialization has started and detects the running kernel version.

## System Setup

- Mounts minimal system filesystems (`proc`, `sysfs`, `devtmpfs`) so the
  environment can interact with processes, devices, and the kernel.
- Runs `depmod` to prepare module dependency lists.
- Loads some base kernel modules that are likely needed for networking and storage.

## Load Hardware Drivers

- Tries to load drivers for:
  - Network cards (Intel, Broadcom, VMware, etc.).
  - Storage controllers (SCSI, AHCI, NVMe, RAID adapters, etc.).
- These steps ensure the environment can see disks and network devices
  regardless of hardware type.

## Device Population

- Populates `/dev` device nodes using either `mdev` or `udevadm`,
depending on what’s available.

## Networking Setup

- Iterates over all non-loopback network interfaces.
- Brings them up and tries to get a DHCP lease with `udhcpc`.
- Allows `udhcpc` to automatically configure the interface and routing.
- Stops at the first interface that gets a lease.
- If no interface obtains a lease, drops to a shell for debugging.

## Kernel Command Line Parsing

- Reads `/proc/cmdline` looking for `img=URL` and `dev=DEVICE` parameters.
- `img=URL` tells the script where to download the OS/disk image.
- `dev=DEVICE` specifies the target device for flashing (defaults to `/dev/sda`).

## Image Download & Flashing

- If no `img=` parameter is found, it drops into a shell for debugging.
- If an image is provided:
  - Downloads it to a temporary file via `wget` (with error checking).
  - If it’s `.gz`, streams directly via `wget | gunzip | dd` without a
    temporary file.
  - Writes the raw image to the target device using `dd`.
  - If download or flashing fails, drops to a shell for debugging.

## Finalization

- Syncs all writes to disk.
- Forces a reboot.
- If something fails before that point, it falls back to a shell for debugging.

---

## In Plain English

This script is essentially a minimal init system for provisioning machines. It:

- Boots enough of Linux to get drivers and networking running.
- Fetches a disk image from a URL (supplied via the kernel command line).
- Writes that image directly onto the specified disk device.
- Reboots into the newly provisioned system.

It’s like a stripped-down installer or PXE boot environment that automates
bare-metal image flashing.
