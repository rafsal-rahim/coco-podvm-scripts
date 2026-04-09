#!/bin/bash
set -ex

# Detect architecture (should be set by parent script, but fallback to detection)
ARCH=${ARCH:-$(uname -m)}

# Determine if this architecture uses UEFI based on detected architecture
if [ "$ARCH" = "s390x" ]; then
    USES_UEFI=${USES_UEFI:-"no"}
else
    USES_UEFI=${USES_UEFI:-"yes"}
fi

export KERNEL_VERSION=6.12.0-124.21.1.el10_1

if [ "$USES_UEFI" = "yes" ]; then
    # x86_64: Install UKI kernel and update UEFI boot
    dnf install -y kernel-{uki-virt,modules,modules-extra}-${KERNEL_VERSION}
    # Update shim fallback CSV to ensure Azure VM boots latest UKI (needed only when kernel is updated)
    printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\"`cat /etc/machine-id`"-"`rpm -q --queryformat %{VERSION}-%{RELEASE}\\\n kernel-uki-virt | tail -1`".x86_64.efi ,UKI bootentry\n" | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV
else
    # s390x: Install standard kernel and update zipl
    # Try to install kernel packages if repos are available, otherwise skip
    if dnf repolist enabled 2>/dev/null | grep -q .; then
        echo "Repositories available, attempting kernel installation..."
        dnf install -y kernel-{modules,modules-extra}-${KERNEL_VERSION} || dnf install -y kernel kernel-modules kernel-modules-extra || true
    else
        echo "No repositories configured, skipping kernel installation"
        echo "Assuming kernel is already installed in base image"
    fi
    
    # Update zipl configuration
    if [ -f /etc/zipl.conf ]; then
        # Get the latest kernel version
        LATEST_KERNEL=$(ls -t /boot/vmlinuz-* | head -1)
        LATEST_INITRD=$(ls -t /boot/initramfs-*.img | grep -v rescue | head -1)
        
        # Update zipl.conf with latest kernel
        sed -i "s|image=.*|image=${LATEST_KERNEL}|" /etc/zipl.conf
        sed -i "s|ramdisk=.*|ramdisk=${LATEST_INITRD}|" /etc/zipl.conf
        
        # Run zipl to update bootloader
        /sbin/zipl
    fi
fi
