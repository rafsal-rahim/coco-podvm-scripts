# Architecture Support: x86_64 and s390x

This document describes the multi-architecture support implemented in this repository for building dm-verity protected qcow2 images.

## Supported Architectures

- **x86_64**: Uses UEFI boot with UKI (Unified Kernel Image) and shim
- **s390x**: Uses zipl bootloader (no UEFI)

## Architecture Detection

The repository now includes automatic architecture detection via `scripts/common/arch-detect.sh`. This script:

1. Detects the target architecture (from `ARCH` environment variable or `uname -m`)
2. Sets architecture-specific variables:
   - Partition type UUIDs
   - Boot configuration (UEFI vs zipl)
   - Console device names
   - Mirror URLs
   - Verity partition types

## Key Differences Between Architectures

### x86_64
- **Boot**: UEFI with shim → GRUB2/UKI
- **Partitions**: EFI System Partition (ESP) + Root
- **Root Partition UUID**: `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`
- **Verity Type**: `root-x86-64-verity`
- **Console**: `ttyS0`
- **Disk Bus**: `scsi`
- **Secure Boot**: Supported via shim and certificates
- **Kernel**: kernel-uki-virt (Unified Kernel Image)

### s390x
- **Boot**: zipl bootloader
- **Partitions**: /boot partition + Root
- **Root Partition UUID**: `5eead9a9-fe09-4a1e-a1d7-520d00531306`
- **Verity Type**: `root-s390x-verity`
- **Console**: `ttysclp0`
- **Disk Bus**: `virtio`
- **Secure Boot**: Different mechanism (not UEFI-based)
- **Kernel**: Standard kernel (kernel-modules, kernel-modules-extra)

## Files Modified for Multi-Architecture Support

### New Files Created

1. **scripts/common/arch-detect.sh**
   - Central architecture detection and configuration
   - Exports architecture-specific variables

2. **helpers/rhel10-dm-root-s390x.ks**
   - Kickstart file for RHEL 10 on s390x
   - Configures zipl bootloader
   - Uses s390x partition UUIDs

3. **helpers/rhel9-dm-root-s390x.ks**
   - Kickstart file for RHEL 9 on s390x
   - Similar to RHEL 10 but for RHEL 9

4. **ARCHITECTURE_SUPPORT.md** (this file)
   - Documentation for multi-architecture support

### Modified Files

1. **scripts/verity/verity.sh**
   - Sources arch-detect.sh
   - Uses dynamic partition UUIDs
   - Renamed functions: `find_efi_root_part` → `find_boot_root_part`
   - Renamed functions: `fix_bootx_cmdline` → `fix_boot_cmdline`
   - Renamed functions: `create_uki_addon` → `create_boot_addon`
   - Conditional logic for UEFI vs zipl
   - Dynamic verity type selection

2. **scripts/coco/coco-components.sh**
   - Sources arch-detect.sh
   - Passes architecture variables to child scripts

3. **scripts/coco/podvm/podvm_maker.sh**
   - Uses architecture-specific CentOS mirror URLs
   - Dynamic based on `$CENTOS_MIRROR_ARCH`

4. **scripts/coco/podvm/script-disk-mods.sh**
   - Conditional kernel installation (UKI for x86_64, standard for s390x)
   - UEFI boot configuration for x86_64
   - zipl configuration for s390x

5. **scripts/create-verity-podvm.sh**
   - Sources arch-detect.sh
   - Exports architecture variables to child scripts

6. **README.md**
   - Added s390x-specific instructions
   - Documented architecture differences
   - Updated step numbers
   - Added architecture-specific examples

## Usage

### Building for x86_64 (default)

```bash
# Architecture is auto-detected or can be explicitly set
export ARCH=x86_64

# Use x86_64 kickstart file
ISO_PATH=rhel-10.0-x86_64-dvd.iso
KS_LOCATION=helpers/rhel10-dm-root.ks
QCOW2_NAME=my-image-x86_64

virt-install --virt-type kvm --os-variant rhel10.0 --arch x86_64 --boot uefi \
    --name $QCOW2_NAME --memory 8192 --location $ISO_PATH \
    --disk bus=scsi,size=7 --initrd-inject=$KS_LOCATION \
    --nographics --extra-args "console=ttyS0 inst.ks=file:/rhel10-dm-root.ks" \
    --transient

# Build container and run
sudo podman build -t my-coco-podvm .
sudo podman run --rm --privileged -e ARCH=x86_64 \
    -v ~/.local/share/libvirt/images/$QCOW2_NAME.qcow2:/disk.qcow2 \
    -v /lib/modules:/lib/modules \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    my-coco-podvm
```

### Building for s390x

```bash
# Set architecture explicitly
export ARCH=s390x

# Use s390x kickstart file
ISO_PATH=rhel-10.0-s390x-dvd.iso
KS_LOCATION=helpers/rhel10-dm-root-s390x.ks
QCOW2_NAME=my-image-s390x

virt-install --virt-type kvm --os-variant rhel10.0 --arch s390x \
    --name $QCOW2_NAME --memory 8192 --location $ISO_PATH \
    --disk bus=virtio,size=7 --initrd-inject=$KS_LOCATION \
    --nographics --extra-args "console=ttysclp0 inst.ks=file:/rhel10-dm-root-s390x.ks" \
    --transient

# Build container and run (no certificates needed for s390x)
sudo podman build -t my-coco-podvm .
sudo podman run --rm --privileged -e ARCH=s390x \
    -v ~/.local/share/libvirt/images/$QCOW2_NAME.qcow2:/disk.qcow2 \
    -v /lib/modules:/lib/modules \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    my-coco-podvm
```

## Environment Variables

- **ARCH**: Target architecture (`x86_64` or `s390x`)
- **ROOT_PARTITION_UUID**: Automatically set based on architecture
- **VERITY_TYPE**: Automatically set based on architecture
- **USES_UEFI**: `yes` for x86_64, `no` for s390x
- **CONSOLE_DEVICE**: `ttyS0` for x86_64, `ttysclp0` for s390x
- **CENTOS_MIRROR_ARCH**: Architecture for CentOS mirror URLs

## Testing

### Prerequisites for s390x Testing
- s390x hardware or QEMU with s390x support
- RHEL s390x ISO
- KVM/libvirt configured for s390x

### Validation Steps
1. Verify kickstart creates correct partition UUIDs
2. Check zipl bootloader installation (s390x)
3. Verify dm-verity partition creation
4. Test boot with verity protection
5. Confirm root filesystem is read-only with overlay

## Cloud Provider Support

- **Azure**: x86_64 only (Azure does not support s390x)
- **IBM Cloud**: s390x support available (requires separate upload script)

## Known Limitations

1. **UKI on s390x**: kernel-uki-virt may not be available for s390x
2. **Secure Boot**: Different mechanisms between architectures
3. **Azure Upload**: Only works for x86_64
4. **Testing**: Requires architecture-specific hardware/emulation

## Future Enhancements

1. Add IBM Cloud upload script for s390x
2. Implement s390x-specific secure boot if available
3. Add automated testing for both architectures
4. Support additional architectures (aarch64, ppc64le)

## Troubleshooting

### s390x Issues

**Problem**: zipl fails to install
- **Solution**: Ensure s390utils packages are installed in kickstart

**Problem**: Wrong partition UUID
- **Solution**: Verify ARCH environment variable is set to s390x

**Problem**: Console not working
- **Solution**: Use `console=ttysclp0` for s390x, not `ttyS0`

### x86_64 Issues

**Problem**: UEFI boot fails
- **Solution**: Ensure `--boot uefi` is specified in virt-install

**Problem**: UKI not found
- **Solution**: Verify kernel-uki-virt package is installed

## Contributing

When adding new features, ensure they work for both architectures:
1. Test with both x86_64 and s390x
2. Use architecture detection from `arch-detect.sh`
3. Add conditional logic where needed
4. Update documentation for both architectures