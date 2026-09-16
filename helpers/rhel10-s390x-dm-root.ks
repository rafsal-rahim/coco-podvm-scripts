# Kickstart for RHEL 10 s390x CoCo PodVM base image
# Use helpers/build-s390x-base-image.sh to run virt-install with this file.
# That script passes ORG_ID and ACTIVATION_KEY as kernel cmdline parameters
# (inst.ks.org_id= and inst.ks.activation_key=) so %post can register RHSM
# without any manual intervention.
#version=RHEL10
text

repo --name="AppStream" --baseurl=file:///run/install/sources/mount-0000-cdrom/AppStream

%addon com_redhat_kdump --disable
%end

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled
cdrom

# Root password — cleared by waagent deprovision at end of %post
rootpw --allow-ssh redhat123

selinux --enforcing

# Only enable services that exist on the minimal install from DVD.
# WALinuxAgent and cloud services are enabled after dnf install in %post.
services --enabled="sshd,NetworkManager"

timezone Etc/UTC --utc
skipx

# Power off automatically when %post completes — no manual intervention needed
poweroff

%packages
@^minimal-environment
openssh-server
kernel
redhat-release

-*gpu-firmware*
-linux-firmware*
-iwl*

# Available on DVD:
tpm2-tools
cryptsetup
cloud-init
e2fsprogs

# NOT on DVD — installed in %post via RHSM after subscription-manager register:
#   WALinuxAgent, cloud-utils-growpart, NetworkManager-cloud-setup,
#   kernel-modules-extra, afterburn, python3-dnf-plugin-versionlock

%end

firstboot --disable

# s390x disk is virtio-blk — exposed as vda
ignoredisk --only-use=vda
clearpart --none --initlabel

# Partition layout:
#   vda1  4 MiB  PReP boot  — required by zipl on s390x
#   vda2  rest   ext4 root  — typed with s390x DPS GUID in %post
part prepboot  --fstype="prepboot" --ondisk=vda --size=4
part /         --fstype="ext4"     --ondisk=vda --grow

%post --erroronfail
set -ex

# ── 1. Fix root partition GUID ────────────────────────────────────────────────
# systemd-repart identifies the root partition by its GPT type UUID.
# Anaconda sets a generic Linux data GUID; overwrite with the s390x-specific
# Discoverable Partitions Spec value so verity-s390x.sh can find it later.
sfdisk --part-type /dev/vda 2 08A7ACEA-624C-4A20-91E8-6E0FA67D23F9

# ── 2. Register with RHSM using credentials passed on the kernel cmdline ──────
# helpers/build-s390x-base-image.sh appends:
#   inst.ks.org_id=<ORG_ID> inst.ks.activation_key=<KEY>
# to the virt-install --extra-args so Anaconda makes them available here.
ORG_ID=$(sed -n 's/.*inst\.ks\.org_id=\([^ ]*\).*/\1/p' /proc/cmdline)
ACTIVATION_KEY=$(sed -n 's/.*inst\.ks\.activation_key=\([^ ]*\).*/\1/p' /proc/cmdline)

if [[ -n "$ORG_ID" && -n "$ACTIVATION_KEY" ]]; then
    subscription-manager register \
        --org="$ORG_ID" \
        --activationkey="$ACTIVATION_KEY"
else
    echo "WARNING: ORG_ID or ACTIVATION_KEY not found on cmdline." >&2
    echo "         Network packages will not be installed."          >&2
    echo "         Pass them via build-s390x-base-image.sh."        >&2
fi

# ── 3. Install packages not available on the DVD ──────────────────────────────
# Only run if we are registered (subscription-manager identity succeeds).
if subscription-manager identity &>/dev/null; then
    dnf install -y \
        WALinuxAgent \
        cloud-utils-growpart \
        NetworkManager-cloud-setup \
        kernel-modules-extra \
        afterburn \
        python3-dnf-plugin-versionlock
    dnf clean all

    # Enable the services that were installed post-DVD
    systemctl enable waagent \
        nm-cloud-setup.service nm-cloud-setup.timer \
        cloud-init cloud-init-local cloud-config cloud-final

    # Unregister — the installed image should not carry active entitlements
    subscription-manager unregister || true
    subscription-manager clean        || true
fi

# ── 4. Kernel install hooks ───────────────────────────────────────────────────
# Disable grub and rescue dracut hooks so future kernel-install runs are fast
# and don't try to build a GRUB config (there is no GRUB on s390x here).
mkdir -p /etc/kernel/install.d
touch /etc/kernel/install.d/20-grub.install
touch /etc/kernel/install.d/50-dracut.install

# ── 5. Lock the bootloader ────────────────────────────────────────────────────
dnf versionlock add s390utils-base 2>/dev/null || true

# ── 6. Deprovision ───────────────────────────────────────────────────────────
# Clears SSH host keys, DHCP leases, cloud-init state so the image is clean.
/usr/sbin/waagent -force -deprovision || true

# ── 7. Reclaim unused blocks ──────────────────────────────────────────────────
fstrim -v / ||:

%end
