# Makefile

SHELL := /bin/bash
ROOT := build/rootfs
BUSYBOX_URL ?= https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
BUSYBOX_BIN := build/busybox
TFTPBOOT ?= /tftpboot

# O/S dist version (required for build/install targets)
ifeq (,$(filter clean distclean help,$(MAKECMDGOALS)))
ifndef DISTRO
$(error DISTRO is not set. Usage: make DISTRO=ubuntu-24.04)
endif
endif
INITRAMFS := build/$(DISTRO).initrd
# Stamp is newer than init, the overlay, and BusyBox only after a successful
# rootfs build. Depending on the rootfs directory itself does not work: make
# treats a directory as unchanged when files inside it are edited.
ROOT_STAMP := build/rootfs.stamp
OVERLAY_FILES := $(shell find rootfs_overlay -type f 2>/dev/null)

.DEFAULT_GOAL := all

# Running kernel version (dynamic)
RUNKVER := $(shell uname -r)

# Kernel/initrd image paths
KERNEL_IMAGE := /boot/vmlinuz-$(RUNKVER)

# Local targets
LOCAL_KERNEL := vmlinuz-$(RUNKVER)

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

.PHONY: all clean distclean modules install help

$(BUSYBOX_BIN):
	$(call notice,Downloading BusyBox)
	@mkdir -p build
	wget -O $@ $(BUSYBOX_URL) || curl -L -o $@ $(BUSYBOX_URL)
	@chmod +x $@

$(ROOT_STAMP): $(BUSYBOX_BIN) init $(OVERLAY_FILES)
	$(call notice,Creating rootfs directories)
	rm -rf $(ROOT)
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

	@$(MAKE) modules-copy
	touch $@

modules: $(ROOT_STAMP)

modules-copy:
	$(call notice,Copying kernel modules for host kernel: $(RUNKVER))
	@if [ ! -d /lib/modules/$(RUNKVER) ]; then \
		echo "Error: /lib/modules/$(RUNKVER) not found on build server."; exit 1; \
	fi
	@mkdir -p $(ROOT)/lib/modules/$(RUNKVER)

	# Copy NIC modules, excluding wireless (.ko, .ko.zst, .ko.xz, .ko.gz)
	@find /lib/modules/$(RUNKVER)/kernel/drivers/net -type f -name '*.ko*' \
		! -path '*/wireless/*' -exec cp --parents {} $(ROOT)/ \;

	# Copy virtio modules
	@find /lib/modules/$(RUNKVER)/kernel/drivers/virtio -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;

	# Copy storage modules
	@find /lib/modules/$(RUNKVER)/kernel/drivers/ata -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/scsi -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/nvme -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;
	@find /lib/modules/$(RUNKVER)/kernel/drivers/block -type f -name '*.ko*' -exec cp --parents {} $(ROOT)/ \;

	# Decompress before generating dependency maps. Host modules.dep entries
	# point at .ko.zst/.ko.xz and will not resolve after unpacking, so those
	# maps are not copied; depmod rebuilds them from the .ko files.
	@if find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.zst' | grep -q .; then \
		if ! command -v zstd >/dev/null 2>&1; then \
			echo "Error: found .ko.zst modules but zstd is not installed."; \
			exit 1; \
		fi; \
		find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.zst' -exec sh -c 'zstd -d -f -q "$$0" && rm -f "$$0"' {} \;; \
	fi
	@if find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.xz' | grep -q .; then \
		if ! command -v xz >/dev/null 2>&1; then \
			echo "Error: found .ko.xz modules but xz is not installed."; \
			exit 1; \
		fi; \
		find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.xz' -exec xz -d -f {} \;; \
	fi
	@if find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.gz' | grep -q .; then \
		find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko.gz' -exec gzip -d -f {} \;; \
	fi
	@if find $(ROOT)/lib/modules/$(RUNKVER) -type f \( -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) | grep -q .; then \
		echo "Error: compressed modules remain after decompression."; \
		exit 1; \
	fi

	# modules.order lists uncompressed names; depmod uses it as the module set.
	@find $(ROOT)/lib/modules/$(RUNKVER) -type f -name '*.ko' \
		| sed 's|^$(ROOT)/lib/modules/$(RUNKVER)/||' \
		| sort > $(ROOT)/lib/modules/$(RUNKVER)/modules.order
	@if [ ! -s $(ROOT)/lib/modules/$(RUNKVER)/modules.order ]; then \
		echo "Error: no kernel modules were copied for $(RUNKVER)."; \
		exit 1; \
	fi
	@cp /lib/modules/$(RUNKVER)/modules.builtin $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true
	@cp /lib/modules/$(RUNKVER)/modules.builtin.modinfo $(ROOT)/lib/modules/$(RUNKVER)/ 2>/dev/null || true

	# Generate dependency maps that point at the unpacked .ko files.
	@depmod -b $(ROOT) $(RUNKVER)
	@if grep -E '\.ko\.(zst|xz|gz)' $(ROOT)/lib/modules/$(RUNKVER)/modules.dep >/dev/null 2>&1; then \
		echo "Error: modules.dep still references compressed modules."; \
		exit 1; \
	fi

	# Copy firmware (for NICs/RAID controllers)
	@cp -a /lib/firmware/* $(ROOT)/lib/firmware/ 2>/dev/null || true

$(INITRAMFS): $(ROOT_STAMP)
	$(call notice,Removing leftover compressed modules)
	@find $(ROOT) \( -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -delete || true
	$(call notice,Creating $(INITRAMFS))
	@set -o pipefail; \
		tmp=$(INITRAMFS).tmp; \
		rm -f "$$tmp"; \
		if cd $(ROOT) && find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../$(DISTRO).initrd.tmp; then \
			mv ../$(DISTRO).initrd.tmp ../$(DISTRO).initrd; \
		else \
			rc=$$?; \
			rm -f ../$(DISTRO).initrd.tmp; \
			exit $$rc; \
		fi
	$(call notice,Done: $(INITRAMFS))

install: all
	$(call notice,Installing kernel and initrd to $(TFTPBOOT)/$(DISTRO)-flash/)
	@mkdir -p $(TFTPBOOT)/$(DISTRO)-flash
	@cp -p $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz~ 2>/dev/null || true
	@cp -p $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd~ 2>/dev/null || true
	cp -p $(LOCAL_KERNEL) $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).vmlinuz
	cp -p $(INITRAMFS) $(TFTPBOOT)/$(DISTRO)-flash/$(DISTRO).initrd
	@{ \
		printf ':$(DISTRO)-flash\n'; \
		printf 'set base http://10.0.0.6/$(DISTRO)-flash\n'; \
		printf 'kernel $${base}/$(DISTRO).vmlinuz \\\n'; \
		printf '    img=$${base}/$(DISTRO).raw.gz \\\n'; \
		printf '    init=/init console=ttyS0,115200n8 console=tty0 \\\n'; \
		printf '    net.ifnames=0 biosdevname=0\n'; \
		printf 'initrd $${base}/$(DISTRO).initrd\n'; \
		printf 'boot\n'; \
	} > $(TFTPBOOT)/$(DISTRO)-flash/ipxe.menu
	$(call notice,Install finished!)

clean:
	$(call notice,Cleaning build artifacts)
	rm -rf $(ROOT) $(ROOT_STAMP)
	rm -f vmlinuz-* build/*.initrd build/*.initrd.tmp

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
