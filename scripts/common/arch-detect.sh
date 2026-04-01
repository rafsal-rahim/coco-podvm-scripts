#!/bin/bash
# Architecture detection and configuration helper
# This script sets architecture-specific variables for building images

detect_arch() {
    # Allow ARCH to be set externally, otherwise detect from system
    ARCH=${ARCH:-$(uname -m)}
    
    case "$ARCH" in
        x86_64|amd64)
            export ARCH="x86_64"
            export ROOT_PARTITION_UUID="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
            export VERITY_TYPE="root-x86-64-verity"
            export SHIM_NAME="shimx64.efi"
            export BOOTLOADER_CSV="BOOTX64.CSV"
            export EFI_SUFFIX="x86_64.efi"
            export USES_UEFI="yes"
            export CENTOS_MIRROR_ARCH="x86_64"
            export CONSOLE_DEVICE="ttyS0"
            export DISK_BUS="scsi"
            echo "Architecture detected: x86_64 (UEFI boot)"
            ;;
        s390x)
            export ARCH="s390x"
            export ROOT_PARTITION_UUID="5eead9a9-fe09-4a1e-a1d7-520d00531306"
            export VERITY_TYPE="root-s390x-verity"
            export USES_UEFI="no"
            export CENTOS_MIRROR_ARCH="s390x"
            export CONSOLE_DEVICE="ttysclp0"
            export DISK_BUS="virtio"
            # s390x uses zipl bootloader, not EFI/UEFI
            export BOOTLOADER_TYPE="zipl"
            echo "Architecture detected: s390x (zipl boot)"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"
            echo "Supported architectures: x86_64, s390x"
            exit 1
            ;;
    esac
}

# Export function for use in other scripts
export -f detect_arch

# Made with Bob
