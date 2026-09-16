#!/bin/bash
# s390x variant of script-disk-mods.sh
# Runs inside the guest via virt-customize (called by coco-components-s390x.sh).
#
# Differences from x86_64:
#   - No EFI/shim/BOOTX64.CSV  — s390x boots via zipl, no shim
#   - No NVIDIA drivers         — NVIDIA has no s390x drivers
#   - No kernel-uki-virt        — does not exist on RHEL 10 s390x;
#                                 s390x uses plain kernel + zipl (no UKI)
#   - KERNEL_VERSION is auto-detected from the running guest if not set
set -ex

# Auto-detect the latest installed kernel if KERNEL_VERSION is not explicitly set.
# Priority: use the newest kernel-core package present in the guest.
if [[ -z "${KERNEL_VERSION:-}" ]]; then
    KERNEL_VERSION=$(rpm -q kernel-core \
        --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | sort -V | tail -1)
    echo "Auto-detected KERNEL_VERSION: ${KERNEL_VERSION}"
else
    echo "Using pinned KERNEL_VERSION: ${KERNEL_VERSION}"
fi

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "ERROR: Could not determine kernel version." >&2
    exit 1
fi

# Install the pinned kernel and module packages.
# On s390x: kernel, kernel-core, kernel-modules, kernel-modules-core,
# kernel-modules-extra — no kernel-uki-virt (does not exist on s390x).
dnf install -y \
    "kernel-${KERNEL_VERSION}" \
    "kernel-core-${KERNEL_VERSION}" \
    "kernel-modules-${KERNEL_VERSION}" \
    "kernel-modules-core-${KERNEL_VERSION}" \
    "kernel-modules-extra-${KERNEL_VERSION}" || true

# Remove all kernel packages that do NOT match KERNEL_VERSION.
# Keep kernel-tools and rescue entries — only remove versioned kernel packages.
echo "Removing non-pinned kernel packages:"
rpm -qa "kernel-*" \
    | grep -Ev "^kernel-(core|modules|modules-core|modules-extra|tools|devel)-${KERNEL_VERSION}" \
    | grep -Ev "^kernel-tools" \
    | grep -E "^kernel-" \
    | xargs -r rpm -e --nodeps || true

# Regenerate initramfs for the pinned kernel.
#
# Two s390x-specific requirements:
#
# 1. --add systemd-veritysetup
#    The veritysetup dracut module is not auto-included when the initramfs is
#    built because roothash= is not yet in the kernel cmdline at this stage
#    (verity is applied later by verity-s390x.sh). Without this flag the
#    module and its generator are absent from the initramfs and the verity
#    device is never assembled at boot.
#
# 2. parse-root.sh patch — bypass the dracut-initqueue wait for veritysetup
#    dracut-107 (RHEL 10.2) only exempts systemd-cryptsetup from the
#    devexists-/dev/mapper/root.sh finished-hook check. systemd-veritysetup is
#    missing from that exemption. Because remote-veritysetup.target is ordered
#    After=remote-fs-pre.target, which only starts after dracut-initqueue exits,
#    the boot deadlocks: dracut-initqueue waits for /dev/mapper/root, but
#    systemd-veritysetup@root.service can only run after dracut-initqueue.
#    The fix adds a one-line veritysetup bypass identical to the existing
#    cryptsetup bypass. The original file is restored immediately after dracut
#    so the host system is unchanged.

PARSE_ROOT=/usr/lib/dracut/modules.d/98dracut-systemd/parse-root.sh

if [[ -f "$PARSE_ROOT" ]]; then
    cp -p "$PARSE_ROOT" "${PARSE_ROOT}.orig"
    sed -i \
        's|grep -q After=remote-fs-pre\.target /run/systemd/generator/systemd-cryptsetup@\*\.service 2>/dev/null|& \&\& ! grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-veritysetup@*.service 2>/dev/null|' \
        "$PARSE_ROOT"
    echo "parse-root.sh patched:"
    grep "veritysetup\|cryptsetup" "$PARSE_ROOT" || true
fi

# Bug #25 fix: patch systemd-volatile-root.service to use 'overlay' mode.
#
# The stock service unit hardcodes:
#   ExecStart=/usr/lib/systemd/systemd-volatile-root yes /sysroot
#
# 'yes' maps to VOLATILE_YES which calls make_volatile() — this uses MS_MOVE to
# relocate /sysroot. MS_MOVE requires the mount to be private or slave, but in
# the initrd PID 1 namespace /sysroot is a shared mount. MS_SLAVE on it returns
# EINVAL (logged as "ignoring"), leaving it shared, so MS_MOVE also returns EINVAL
# and the service exits 1, which blocks initrd-root-fs.target → emergency shell.
#
# 'overlay' maps to VOLATILE_OVERLAY which calls make_overlay() — this mounts a
# plain overlayfs (lowerdir=/sysroot, upperdir=tmpfs/upper, workdir=tmpfs/work)
# directly on /sysroot with no MS_MOVE at all. Works on shared mounts.
#
# Dracut copies /usr/lib/systemd/system/ units into the initramfs but does NOT
# automatically include /etc/systemd/system/ drop-ins. Patching the source unit
# directly (same pattern as parse-root.sh above) ensures the fix is baked in.
# The file is restored immediately after dracut so the installed system is unchanged.
# A persistent drop-in is also written to /etc/systemd/system/ so the service
# behaves correctly after pivot_root if systemd.volatile=overlay is on the cmdline.
VOLATILE_SVC=/usr/lib/systemd/system/systemd-volatile-root.service

cp -p "$VOLATILE_SVC" "${VOLATILE_SVC}.orig"
sed -i 's|ExecStart=/usr/lib/systemd/systemd-volatile-root yes |ExecStart=/usr/lib/systemd/systemd-volatile-root overlay |' \
    "$VOLATILE_SVC"
echo "systemd-volatile-root.service patched:"
grep "ExecStart" "$VOLATILE_SVC"

# Also write a persistent drop-in for the real root (post-pivot_root boots)
mkdir -p /etc/systemd/system/systemd-volatile-root.service.d
cat > /etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot
EOF

dracut --force --kver "${KERNEL_VERSION}.s390x" --add "systemd-veritysetup" --add-drivers "overlay"

# Restore the original service unit so the installed system is unchanged
mv "${VOLATILE_SVC}.orig" "$VOLATILE_SVC"
echo "systemd-volatile-root.service restored."

if [[ -f "${PARSE_ROOT}.orig" ]]; then
    mv "${PARSE_ROOT}.orig" "$PARSE_ROOT"
    echo "parse-root.sh restored."
fi

# Update zipl boot record to reflect the pinned kernel
zipl --verbose

# xmlsec1 is required by the CoCo attestation flow
dnf install -y xmlsec1 xmlsec1-openssl

dnf clean all
