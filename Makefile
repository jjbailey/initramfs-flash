# Makefile

SHELL := /bin/bash
ROOT := build/rootfs
BUSYBOX_URL ?= https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
BUSYBOX_BIN := build/busybox
TFTPBOOT ?= ../tftpboot

# O/S dist version (required for build/install targets)
ifeq (,$(filter clean distclean help,$(MAKECMDGOALS)))
ifndef DISTRO
$(error DISTRO is not set. Usage: make DISTRO=ubuntu-24.04)
endif
endif
INITRAMFS := build/$(DISTRO).initrd

.DEFAULT_GOAL := all

# Running kernel version (dynamic)
RUNKVER := $(shell uname -r)

# Kernel/initrd image paths
KERNEL_IMAGE := /boot/vmlinuz-$(RUNKVER)

# Local targets
LOCAL_KERNEL := vmlinuz-$(RUNKVER)

notice = @echo "==> $1"

all: $(LOCAL_KERNEL) $(INITRAMFS)

# Ensure kernel image exists before copying
$(LOCAL_KERNEL):
	@if [ ! -e "$(KERNEL_IMAGE)" ]; then \
		echo "Error: Kernel image not found: $(KERNEL_IMAGE)"; \
		exit 1; \
	fi
	$(call notice,Copying $(KERNEL_IMAGE))
	@sudo cp -p "$(KERNEL_IMAGE)" "$@"
	@sudo chmod 644 "$@"

# NIC drivers and dependencies
KNOWN_NIC_MODULES := ixgbe i40e e1000e igb virtio_net vmxnet3 bnx2 bnx2x tg3
KNOWN_DEP_MODULES := libphy i2c-core ptp mdio net_failover failover mii

# BusyBox applets
BIN_APPLETS := sh awk cat dd dmesg find grep gunzip head ip ln \
		ls lsmod mkdir sleep sort sync tail udhcpc uname wget

SBIN_APPLETS := blkid blockdev depmod ifconfig insmod modprobe \
		mount poweroff reboot umount

# Notice macro for colored output
define notice
	@echo -e "\033[1;33m==[ $(1) ]==\033[0m"; sleep 1
endef

# Create symlinks for BusyBox
define install_busybox_links
	@for app in $(1); do \
		ln -sf /bin/busybox $(ROOT)/$(2)/$$app; \
	done
endef

.PHONY: all clean distclean $(ROOT) modules install help

$(BUSYBOX_BIN):
	$(call notice,Downloading BusyBox)
	@mkdir -p build
	wget -O $@ $(BUSYBOX_URL) || curl -L -o $@ $(BUSYBOX_URL)
	@chmod +x $@

$(ROOT): $(BUSYBOX_BIN)
	$(call notice,Creating rootfs directories)
	mkdir -p $(ROOT)/bin $(ROOT)/sbin $(ROOT)/etc/udhcpc $(ROOT)/proc $(ROOT)/sys \
		$(ROOT)/dev $(ROOT)/tmp $(ROOT)/lib/firmware

	$(call notice,Installing BusyBox)
	ln -f $(BUSYBOX_BIN) $(ROOT)/bin/busybox

	$(call notice,Installing BusyBox symlinks)
	$(call install_busybox_links,$(BIN_APPLETS),bin)
	$(call install_busybox_links,$(SBIN_APPLETS),sbin)

	$(call notice,Copying init script and overlay...)
	cp init $(ROOT)/
	chmod +x $(ROOT)/init
	cp -r rootfs_overlay/* $(ROOT)/

	@$(MAKE) modules

modules:
	$(call notice,Copying kernel modules for host kernel: $(RUNKVER))
	@if [ ! -d /lib/modules/$(RUNKVER) ]; then \
		echo "Error: /lib/modules/$(RUNKVER) not found on build server."; exit 1; \
	fi
	@mkdir -p $(ROOT)/lib/modules/$(RUNKVER)

	# Copy NIC modules, excluding wireless
	@find /lib/modules/$(RUNKVER)/kernel/drivers/net -type f \( -name '*.ko' -o -name '*.ko.zst' \) \
		! -path '*/wireless/*' -exec cp --parents {} $(ROOT)/ \;

	# Copy Broadcom NICs (common on HP Gen9)
	@find /lib/modules/$(RUNKVER)/kernel/drivers/net/ethernet/broadcom -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;

	# Copy virtio modules
	@find /lib/modules/$(RUNKVER)/kernel/drivers/virtio -type f \( -name '*.ko' -o -name '*.ko.zst' \) -exec cp --parents {} $(ROOT)/ \;

	# Copy storage modules
	@find /lib/modules/$(RUNKVER)/kernel/drivers/ata -type f \( -name '*.ko' -o -name '*.ko.zst' \) -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/scsi -type f \( -name '*.ko' -o -name '*.ko.zst' \) -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/nvme -type f \( -name '*.ko' -o -name '*.ko.zst' \) -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/block -type f \( -name '*.ko' -o -name '*.ko.zst' \) -exec cp --parents {} $(ROOT)/ \;

	# HP Smart Array / RAID controllers
	@find /lib/modules/$(RUNKVER)/kernel/drivers/scsi -type f \( -name 'hpsa.ko*' -o -name 'cciss.ko*' -o -name 'megaraid_sas.ko*' -o -name 'mpt*.ko*' \) -exec cp --parents {} $(ROOT)/ \;

	# VMware paravirtual SCSI driver
	@find /lib/modules/$(RUNKVER)/kernel/drivers/scsi -type f -name 'vmw_pvscsi.ko*' -exec cp --parents {} $(ROOT)/ \;

	# Decompress .ko.zst if zstd exists
	@if command -v zstd >/dev/null 2>&1; then \
		find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.zst' -exec sh -c 'zstd -d -f "$$0"' {} \;; \
	fi

	# Remove leftover .zst files
	@find $(ROOT)/lib/modules/$(RUNKVER) -name '*.ko.zst' -delete

	# Copy dependency + metadata files
	@cp /lib/modules/$(RUNKVER)/modules.dep* $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true
	@cp /lib/modules/$(RUNKVER)/modules.alias* $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true
	@cp /lib/modules/$(RUNKVER)/modules.builtin* $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true
	@cp /lib/modules/$(RUNKVER)/modules.order $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true

	# Generate new dependency maps inside initrd
	@depmod -b $(ROOT) $(RUNKVER)

	# Copy firmware (for NICs/RAID controllers)
	@cp -a /lib/firmware/* $(ROOT)/lib/firmware/ 2>/dev/null || true

$(INITRAMFS): $(ROOT)
	$(call notice,Removing leftover .zst files)
	@find $(ROOT) -name '*.zst' -delete || true
	$(call notice,Creating $(INITRAMFS))
	cd $(ROOT) && find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../../$(INITRAMFS)
	$(call notice,Done: $(INITRAMFS))

install: all
	$(call notice,Installing kernel and initrd to $(TFTPBOOT)/$(DISTRO)-flash/)
	@if [ ! -f $(LOCAL_KERNEL) ]; then \
		echo "Error: $(LOCAL_KERNEL) not built yet. Run 'make all' first."; exit 1; \
	fi
	@if [ ! -f $(INITRAMFS) ]; then \
		echo "Error: $(INITRAMFS) not present. Run 'make all' first."; exit 1; \
	fi
	cp -p $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz~
	cp -p $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd~
	cp -p $(LOCAL_KERNEL) $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz
	cp -p $(INITRAMFS) $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd
	$(call notice,Install finished!)

clean:
	$(call notice,Cleaning build artifacts)
	rm -rf $(ROOT)
	rm -f vmlinuz-* build/*.initrd

distclean: clean
	$(call notice,Removing downloaded BusyBox)
	rm -f $(BUSYBOX_BIN)

help:
	@echo "Available targets:"
	@echo "  all      - Build kernel and initramfs"
	@echo "  clean    - Clean build artifacts"
	@echo "  install  - Install kernel and initramfs to tftpboot"
	@echo "  modules  - Copy kernel modules to rootfs"
	@echo "  help     - Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  DISTRO   - Distribution version (required, e.g. ubuntu-24.04)"
	@echo "  BUSYBOX_URL - URL to download BusyBox (default: $(BUSYBOX_URL))"
	@echo "  TFTPBOOT    - Path to tftpboot directory (default: $(TFTPBOOT))"
