#!/bin/bash
# s390x variant of podvm_maker.sh
# Runs inside the guest via virt-customize (called by coco-components-s390x.sh).
#
# Differences from x86_64:
#   - CentOS mirror uses s390x path instead of x86_64
#   - Serial console unit is ttysclp0 (s390x line-mode console), not ttyS0
#   - afterburn and e2fsprogs may already be installed (base image has them);
#     use --skip-broken / idempotent install
set -ex

# afterburn and e2fsprogs are in RHSM repos.
# If ACTIVATION_KEY + ORG_ID are exported (from coco-components-s390x.sh),
# the image is already registered; otherwise fall back to the CentOS mirror.
if subscription-manager identity &>/dev/null; then
    dnf install -y afterburn e2fsprogs || true
else
    dnf config-manager \
        --add-repo=https://mirror.stream.centos.org/10-stream/AppStream/s390x/os/
    dnf install -y --nogpgcheck afterburn e2fsprogs || true
    dnf clean all
    dnf config-manager --set-disabled "*centos*"
fi

# Afterburn provider check-in (Azure)
cat <<EOF > /etc/systemd/system/afterburn-checkin.service
[Unit]
ConditionKernelCommandLine=

[Service]
ExecStart=
ExecStart=-/usr/bin/afterburn --provider=azure --check-in
EOF
ln -sf ../afterburn-checkin.service \
    /etc/systemd/system/multi-user.target.wants/afterburn-checkin.service

# Extract CoCo payload tarballs
tar -xzvf /tmp/podvm-binaries.tar.gz -C /
tar -xzvf /tmp/pause-bundle.tar.gz -C /
tar -xzvf /tmp/luks-config.tar.gz -C /

# Remove cloud-init and WALinuxAgent — kata-agent takes over from this point
dnf remove -y cloud-init WALinuxAgent || true

# Fix podns@netns service — SELinux label for /usr/bin/ip
semanage fcontext -a -t bin_t /usr/bin/ip && restorecon -v /usr/sbin/ip

# Enable the LUKS scratch partition service
systemctl enable /etc/systemd/system/luks-scratch.service

# Print vTPM PCR values to the serial console at boot
cat <<'SCRIPT' > /usr/libexec/gen-issue
#!/usr/bin/env bash
set -euo pipefail

if ! tpm2_pcrread sha256:0 > /dev/null 2>&1; then
   echo "No vTPM detected"
   exit 0
fi

mkdir -p /run/issue.d
rm -f /etc/issue.net
rm -f /etc/issue
{
  echo "Detected vTPM PCR values:"
  /usr/bin/tpm2_pcrread sha256:all
  echo
} > /run/issue.d/30-pcrs.issue
SCRIPT

mv /etc/issue.d /usr/lib/issue.d || true
rm -f /etc/issue.net
rm -f /etc/issue
chmod +x /usr/libexec/gen-issue

# s390x serial console unit is ttysclp0 (not ttyS0)
cat <<EOF > /etc/systemd/system/gen-issue.service
[Unit]
Description=Generate issue to print to serial console at startup
Before=serial-getty@ttysclp0.service
After=process-user-data.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/gen-issue

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../gen-issue.service \
    /etc/systemd/system/multi-user.target.wants/gen-issue.service

# Extend PCR8 with the initdata digest after process-user-data runs
mkdir -p /etc/systemd/system/process-user-data.service.d/
cat <<'EOF' > /etc/systemd/system/process-user-data.service.d/10-override.conf
[Service]
ExecStartPre=-/bin/mount -t iso9660 -o ro /dev/disk/by-label/cidata /media/cidata
ExecStartPost=-/bin/bash -c 'tpm2_pcrextend 8:sha256=$(head -c64 /run/peerpod/initdata.digest)'
EOF

# Open firewall port required for CoCo networking
firewall-offline-cmd --zone=public --add-port=15150/tcp
