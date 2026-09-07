# Initramfs Boot Flow

<!-- markdownlint-disable MD013 -->

```mermaid
flowchart TD
    A["Baremetal Machine<br/>Firmware / BIOS"]
    B[iPXE ROM]
    C["Kernel + Initramfs<br/>loaded by iPXE"]

    subgraph ramdisk ["RAM Disk (initramfs as /)"]
        D1["/bin/busybox<br/>/init<br/>/etc/udhcpc<br/>/tmp"]
        D2["/proc ← virtual<br/>/sys  ← virtual<br/>/dev  ← populated at runtime"]
        D3["/sbin/ ← blkid blockdev modprobe mount etc."]
        D4["/lib/modules/ ← NIC, storage, virtio drivers<br/>/lib/firmware/ ← NIC and RAID firmware"]
        D1 ~~~ D2
        D3 ~~~ D4
    end

    E1["/init loads kernel modules<br/>NIC, storage, virtio, RAID"]
    E2["/init sets up networking<br/>via udhcpc"]
    E3["/init downloads and flashes image<br/>img= URL → block device"]
    F[reboot]

    A --> B
    B -->|"Downloads kernel + initramfs"| C
    C -->|"Kernel mounts initramfs as /"| ramdisk
    ramdisk --> E1
    E1 --> E2
    E2 --> E3
    E3 --> F
```
