# Kickstart for creating a RHEL9 s390x CVM

# Use text install
text

# Do not run the Setup Agent on first boot
firstboot --disable

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'

# System language
lang en_US.UTF-8

# Network information
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled

# Use CDROM
cdrom

# Root password. It will be reset by cloud-init
rootpw redhat123

# Enable SELinux
selinux --enforcing

# System services
services --enabled="sshd,NetworkManager,cloud-init,cloud-init-local,cloud-config,cloud-final"

# System timezone
timezone Etc/UTC --utc

# Don't configure X
skipx

# Power down the machine after install
# poweroff
reboot

%pre --erroronfail
sfdisk --wipe always -X gpt /dev/sda << EOF
2048,2097152,0FC63DAF-8483-4772-8E79-3D69D8477DE4
,5242880,5EEAD9A9-FE09-4A1E-A1D7-520D00531306
EOF
%end

part /boot --onpart=sda1 --fstype ext4
part / --onpart=sda2 --fstype ext4

%packages
@^minimal-environment
openssh-server
kernel
redhat-release

-linux-firmware*
-iwl*

cloud-init
cloud-utils-growpart

NetworkManager

tpm2-tools
cryptsetup

# s390x specific packages
s390utils
s390utils-base

# Standard kernel for s390x
kernel
kernel-modules
kernel-modules-extra

# versionlock plugin
python3-dnf-plugin-versionlock

afterburn
e2fsprogs

%end

%post --erroronfail
# installer may change partition GUIDs. Linux root (s390x):
sfdisk --part-type /dev/vda 2 5EEAD9A9-FE09-4A1E-A1D7-520D00531306

# Install and configure zipl bootloader for s390x
echo "Configuring zipl bootloader..."

# Get the kernel version
KERNEL_VERSION=$(ls /boot/vmlinuz-* | sed 's/.*vmlinuz-//' | head -1)
ROOT_UUID=$(blkid -s UUID -o value /dev/vda2)

# Create zipl configuration
cat > /etc/zipl.conf << EOF
[defaultboot]
defaultauto
prompt=1
timeout=5
default=linux
target=/boot

[linux]
image=/boot/vmlinuz-${KERNEL_VERSION}
ramdisk=/boot/initramfs-${KERNEL_VERSION}.img
parameters="root=UUID=${ROOT_UUID} console=ttysclp0"
EOF

# Run zipl to install bootloader
zipl

# Fstrim root
fstrim -v / ||:

%end