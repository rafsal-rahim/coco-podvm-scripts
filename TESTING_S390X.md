# Testing s390x Build on RHEL s390x VM

Yes, you can build and test this on an s390x RHEL VM! Here's a complete guide.

## Prerequisites

### 1. s390x RHEL VM Requirements
- RHEL 9 or RHEL 10 on s390x architecture
- At least 16GB RAM (8GB minimum)
- 50GB+ free disk space
- Root or sudo access
- Network connectivity

### 2. Verify Architecture
```bash
uname -m
# Should output: s390x

cat /etc/redhat-release
# Should show RHEL version
```

## Installation Steps

### Step 1: Install Required Packages

```bash
# Update system
sudo dnf update -y

# Install virtualization tools
sudo dnf install -y qemu-kvm libvirt virt-install virt-manager

# Install build tools
sudo dnf install -y podman buildah git

# Install image manipulation tools
sudo dnf install -y qemu-img libguestfs-tools guestfs-tools

# Install additional dependencies
sudo dnf install -y cpio systemd-ukify jq openssl sbsigntools

# Install s390x specific tools
sudo dnf install -y s390utils s390utils-base

# Start and enable libvirt
sudo systemctl start libvirtd
sudo systemctl enable libvirtd
```

### Step 2: Clone the Repository

```bash
cd ~
git clone <your-repo-url>
cd coco-podvm-scripts
```

### Step 3: Download RHEL s390x ISO

You'll need a RHEL s390x ISO. Download it from Red Hat Customer Portal:
- RHEL 10: `rhel-10.0-s390x-dvd.iso`
- RHEL 9: `rhel-9.x-s390x-dvd.iso`

```bash
# Place the ISO in your home directory or a known location
ISO_PATH=~/rhel-10.0-s390x-dvd.iso
```

### Step 4: Set Architecture Environment Variable

```bash
export ARCH=s390x
```

### Step 5: Create Base Image with virt-install

```bash
# Set variables
ISO_PATH=~/rhel-10.0-s390x-dvd.iso
KS_LOCATION=helpers/rhel10-dm-root-s390x.ks
QCOW2_NAME=my-s390x-test-image

# Create the VM and install
sudo virt-install \
    --virt-type kvm \
    --os-variant rhel10.0 \
    --arch s390x \
    --name $QCOW2_NAME \
    --memory 8192 \
    --location $ISO_PATH \
    --disk path=/var/lib/libvirt/images/$QCOW2_NAME.qcow2,format=qcow2,bus=virtio,size=7 \
    --initrd-inject=$KS_LOCATION \
    --nographics \
    --extra-args "console=ttysclp0 inst.ks=file:/rhel10-dm-root-s390x.ks" \
    --transient

# Wait for installation to complete (VM will power off automatically)
# This may take 15-30 minutes
```

### Step 6: Verify the Base Image

```bash
# Check if image was created
sudo ls -lh /var/lib/libvirt/images/$QCOW2_NAME.qcow2

# Get image info
sudo qemu-img info /var/lib/libvirt/images/$QCOW2_NAME.qcow2
```

### Step 7: Build the Container

```bash
cd ~/coco-podvm-scripts

# Build the container
sudo podman build -t my-coco-podvm .

# Verify container was built
sudo podman images | grep my-coco-podvm
```

### Step 8: Run the Container to Apply dm-verity

```bash
# Set the QCOW2 path
QCOW2=/var/lib/libvirt/images/$QCOW2_NAME.qcow2

# Run the container (no certificates needed for s390x)
sudo podman run --rm \
    --privileged \
    -e ARCH=s390x \
    -v $QCOW2:/disk.qcow2 \
    -v /lib/modules:/lib/modules:ro \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    my-coco-podvm

# This process may take 10-20 minutes
```

### Step 9: Verify the Result

```bash
# Check the modified image
sudo qemu-img info $QCOW2

# The image should now have:
# 1. CoCo components installed
# 2. dm-verity partition created
# 3. zipl configured with verity parameters
```

## Testing the Built Image

### Option 1: Boot Test with virt-install

```bash
# Boot the image to test
sudo virt-install \
    --virt-type kvm \
    --os-variant rhel10.0 \
    --arch s390x \
    --name test-s390x-boot \
    --memory 4096 \
    --disk path=$QCOW2,format=qcow2,bus=virtio \
    --import \
    --nographics \
    --console pty,target_type=sclp

# You should see:
# - Boot messages on ttysclp0
# - dm-verity initialization
# - Root filesystem mounted as read-only with overlay
```

### Option 2: Inspect with guestfish

```bash
# Mount and inspect the image
sudo guestfish -a $QCOW2 -i

# Inside guestfish, check:
><fs> ls /
><fs> cat /etc/zipl.conf
><fs> ls /usr/local/bin
><fs> exit
```

### Option 3: Check Partitions

```bash
# Use qemu-nbd to inspect partitions
sudo modprobe nbd max_part=8
sudo qemu-nbd -c /dev/nbd0 -f qcow2 $QCOW2

# List partitions
sudo lsblk /dev/nbd0

# You should see:
# - /dev/nbd0p1: /boot partition
# - /dev/nbd0p2: root partition
# - /dev/nbd0p3: verity partition (newly created)

# Check partition types
sudo sfdisk -l /dev/nbd0

# Disconnect
sudo qemu-nbd -d /dev/nbd0
```

## Validation Checklist

- [ ] Architecture detected as s390x
- [ ] Base image created with correct partition UUIDs
- [ ] zipl bootloader installed and configured
- [ ] Container built successfully
- [ ] dm-verity partition created
- [ ] Verity hash calculated
- [ ] zipl.conf updated with roothash parameter
- [ ] Image boots successfully
- [ ] Root filesystem is read-only with overlay
- [ ] CoCo components installed

## Troubleshooting

### Issue: "Architecture not supported"
**Solution**: Ensure `ARCH=s390x` is exported before running scripts

### Issue: virt-install fails
**Solution**: 
- Check if KVM is available: `lsmod | grep kvm`
- Verify libvirt is running: `sudo systemctl status libvirtd`
- Check s390x support: `virsh capabilities | grep s390x`

### Issue: Container build fails
**Solution**:
- Check if podman is installed: `podman --version`
- Verify network connectivity
- Check disk space: `df -h`

### Issue: qemu-nbd not available
**Solution**: Install qemu-img package: `sudo dnf install -y qemu-img`

### Issue: zipl configuration fails
**Solution**:
- Verify s390utils is installed: `rpm -q s390utils`
- Check if /boot partition exists in the image
- Verify zipl.conf syntax

### Issue: dm-verity partition not created
**Solution**:
- Check if systemd-repart supports s390x
- Verify disk has enough space (needs ~7% extra)
- Check logs in container output

## Quick Test Script

Create a test script to automate the process:

```bash
#!/bin/bash
# test-s390x-build.sh

set -e

echo "=== s390x Build Test ==="
echo "Architecture: $(uname -m)"

# Set variables
export ARCH=s390x
ISO_PATH=~/rhel-10.0-s390x-dvd.iso
QCOW2_NAME=test-s390x-$(date +%Y%m%d-%H%M%S)
QCOW2=/var/lib/libvirt/images/$QCOW2_NAME.qcow2

echo "Step 1: Creating base image..."
sudo virt-install \
    --virt-type kvm \
    --os-variant rhel10.0 \
    --arch s390x \
    --name $QCOW2_NAME \
    --memory 8192 \
    --location $ISO_PATH \
    --disk path=$QCOW2,format=qcow2,bus=virtio,size=7 \
    --initrd-inject=helpers/rhel10-dm-root-s390x.ks \
    --nographics \
    --extra-args "console=ttysclp0 inst.ks=file:/rhel10-dm-root-s390x.ks" \
    --transient

echo "Step 2: Building container..."
sudo podman build -t my-coco-podvm .

echo "Step 3: Applying dm-verity..."
sudo podman run --rm \
    --privileged \
    -e ARCH=s390x \
    -v $QCOW2:/disk.qcow2 \
    -v /lib/modules:/lib/modules:ro \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    my-coco-podvm

echo "Step 4: Verifying result..."
sudo qemu-img info $QCOW2

echo "=== Build Complete ==="
echo "Image location: $QCOW2"
echo "To test boot: sudo virt-install --import --disk path=$QCOW2 --arch s390x --memory 4096 --name test-boot"
```

Save and run:
```bash
chmod +x test-s390x-build.sh
./test-s390x-build.sh
```

## Expected Output

When successful, you should see:
1. Base image created with s390x partitions
2. Container build completes without errors
3. dm-verity partition added to image
4. zipl configuration updated with roothash
5. Image boots with verity protection active

## Performance Notes

On s390x hardware:
- Base image creation: 15-30 minutes
- Container build: 5-10 minutes
- dm-verity application: 10-20 minutes
- Total time: ~45-60 minutes

The build process is fully supported on s390x RHEL VMs and should work identically to x86_64 builds (with architecture-specific differences handled automatically).