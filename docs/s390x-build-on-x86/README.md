# Building a dm-verity Enabled s390x qcow2 Image on an x86 Host

**Branch:** `support-s390x-podvm-image`  
**Last updated:** 2026-10-07  
**Purpose:** Step-by-step guide to cross-compiling the RHEL 10 s390x CoCo PodVM base image
(dm-verity protected qcow2) entirely from an x86_64 Linux machine without access to
real IBM Z hardware.

---

## Quick Reference — What Changes vs Native s390x Build

| What | Native (s390x KVM host) | Cross-build (x86 host) |
|---|---|---|
| `virt-install` | `--virt-type kvm` | `--virt-type qemu --emulator qemu-system-s390x` |
| `virt-customize` | no extra config | `LIBGUESTFS_HV=/usr/bin/qemu-system-s390x` |
| Build time (Stage 1) | ~15 min | ~1–3 hours |
| Build time (Stage 2) | ~20 min | ~30–60 min |
| Everything else | unchanged | unchanged |

---

## Table of Contents

1. [Architecture — what is actually running where](#1-architecture)
2. [Host machine requirements](#2-host-machine-requirements)
3. [Install required packages on the x86 host](#3-install-required-packages)
4. [Verify QEMU s390x emulation works](#4-verify-qemu-s390x-emulation)
5. [Clone the repository and prepare workspace](#5-clone-and-prepare)
6. [Obtain the RHEL 10 s390x DVD ISO](#6-obtain-the-iso)
7. [Stage 1 — build the base qcow2 with `virt-install`](#7-stage-1--build-the-base-qcow2)
8. [Verify the base image](#8-verify-the-base-image)
9. [Stage 2 — apply CoCo components and dm-verity](#9-stage-2--coco-components-and-dm-verity)
10. [Verify the final verity image](#10-verify-the-final-image)
11. [Troubleshooting](#11-troubleshooting)
12. [Why these specific fixes work (deep-dive)](#12-why-these-fixes-work)

---

## 1. Architecture

Understanding what runs where prevents confusion when things go wrong.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Your x86_64 Linux Host                           │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Stage 1: qemu-system-s390x (software CPU emulation)        │    │
│  │                                                              │    │
│  │   virt-install                                               │    │
│  │       │                                                      │    │
│  │       └─► qemu-system-s390x (emulated s390x machine)        │    │
│  │                  │                                           │    │
│  │                  ├─► Anaconda installer (s390x RHEL)         │    │
│  │                  ├─► kickstart rhel10-s390x-dm-root.ks       │    │
│  │                  ├─► partition: PReP(vda1) + ext4(vda2)      │    │
│  │                  ├─► RHSM register, dnf install              │    │
│  │                  └─► zipl writes bootloader                  │    │
│  │                                                              │    │
│  │   Output: rhel10-s390x-base.qcow2  (raw RHEL install)       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Stage 2: CoCo components + dm-verity                        │    │
│  │                                                              │    │
│  │  2a. coco-components-s390x.sh                                │    │
│  │       │                                                      │    │
│  │       └─► virt-customize                                     │    │
│  │               │                                              │    │
│  │               └─► LIBGUESTFS_HV=qemu-system-s390x           │    │
│  │                       │                                      │    │
│  │                       └─► s390x appliance VM                 │    │
│  │                               ├─► script-disk-mods-s390x.sh │    │  ← dnf, dracut, zipl
│  │                               └─► podvm_maker-s390x.sh      │    │  ← CoCo binaries, units
│  │                                                              │    │
│  │  2b. verity-s390x.sh  (x86-native tools, no VM needed)      │    │
│  │       ├─► qemu-img resize                                    │    │  ← x86 tool, works natively
│  │       ├─► qemu-nbd    (mount qcow2 as block device)         │    │  ← x86 tool, works natively
│  │       ├─► systemd-repart (add verity hash GPT partition)    │    │  ← x86 tool, works natively
│  │       ├─► mount + BLS entry patching (sed)                  │    │  ← x86 tool, works natively
│  │       ├─► virt-customize → zipl  (needs LIBGUESTFS_HV)      │    │  ← needs s390x appliance VM
│  │       └─► veritysetup format (compute roothash)             │    │  ← x86 tool, works natively
│  │                                                              │    │
│  │   Output: rhel10-s390x-base.qcow2 (dm-verity protected)     │    │
│  │           rhel10-s390x-base.qcow2.roothash                  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

**Key insight:** Only the two `virt-customize` calls and the initial `virt-install` require
s390x CPU emulation. All disk manipulation (qemu-nbd, systemd-repart, veritysetup, BLS
patching) runs natively on the x86 host kernel against the qcow2 file.

---

## 2. Host Machine Requirements

- **OS:** Fedora 39+ or RHEL 9+ on x86_64 (other distros work but package names differ)
- **RAM:** Minimum 16 GiB. Stage 1 allocates 8 GiB to the emulated VM; Stage 2 allocates
  8 GiB to the libguestfs appliance. They do not run simultaneously, but the host needs
  headroom.
- **Disk:** ~25 GiB free in the output directory
  - RHEL 10 s390x DVD ISO: ~9 GiB
  - ISO extraction/mount temp space: ~9 GiB
  - Base qcow2 (virtual 7 GiB, actual ~1 GiB compressed): ~2 GiB
  - After Stage 2 resize and verity: ~10 GiB virtual, ~2 GiB actual
- **CPU:** Any modern x86_64 CPU. No KVM/virtualisation extensions required —
  `qemu-system-s390x` is pure software emulation.
- **Network:** Outbound HTTPS to `subscription.rhsm.redhat.com` and
  `cdn.redhat.com` for RHSM registration inside the VM during Stage 1.

---

## 3. Install Required Packages

### Fedora

```bash
sudo dnf install -y \
    qemu-system-s390x \
    virt-install \
    libvirt \
    libvirt-daemon-kvm \
    guestfs-tools \
    libguestfs \
    libguestfs-appliance \
    qemu-img \
    qemu-nbd \
    nbd \
    systemd-container \
    jq \
    cryptsetup \
    util-linux
```

### RHEL 9 (with EPEL)

```bash
sudo subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms
sudo dnf install -y epel-release

sudo dnf install -y \
    @virtualization \
    qemu-kvm-device-s390x-zcrypt \
    virt-install \
    guestfs-tools \
    libguestfs \
    libguestfs-appliance \
    qemu-img \
    nbd \
    jq \
    cryptsetup

# qemu-system-s390x may be in a separate package on RHEL 9:
sudo dnf install -y qemu-kvm-block-rbd || true   # pull in qemu-system-s390x as dep
```

### Ubuntu 22.04 / 24.04

```bash
sudo apt-get install -y \
    qemu-system-misc \
    qemu-utils \
    qemu-block-extra \
    libguestfs-tools \
    virt-manager \
    libvirt-daemon-system \
    nbd-client \
    jq \
    cryptsetup-bin \
    util-linux
```

### Verify the s390x QEMU binary is present

```bash
which qemu-system-s390x
qemu-system-s390x --version
# Expected: QEMU emulator version 8.x.x (or later)
```

---

## 4. Verify QEMU s390x Emulation Works

Before attempting a multi-hour build, confirm that `qemu-system-s390x` can start
an s390x machine at all:

```bash
qemu-system-s390x \
    -nographic \
    -m 512M \
    -no-reboot \
    -kernel /dev/null \
    2>&1 | head -5
# Expected: QEMU starts and immediately exits or prints a boot error
# (no kernel = expected failure, but the binary ran = emulation works)
```

Also confirm libvirt knows about the s390x emulator:

```bash
sudo systemctl start libvirtd
virsh capabilities | grep -A2 s390x
# Expected: <arch name='s390x'> block appears
```

If `virsh capabilities` shows no s390x entry, verify:

```bash
ls -la /usr/bin/qemu-system-s390x   # binary must exist
sudo virsh domcapabilities --arch s390x --machine s390-ccw-virtio
```

---

## 5. Clone and Prepare

```bash
git clone https://github.com/confidential-containers/coco-podvm-scripts.git
cd coco-podvm-scripts
git checkout support-s390x-podvm-image

# Create the output directory
mkdir -p ../output
```

---

## 6. Obtain the RHEL 10 s390x DVD ISO

Download the RHEL 10 s390x DVD ISO from the Red Hat Customer Portal:

```
https://access.redhat.com/downloads/content/rhel
→ Red Hat Enterprise Linux 10
→ Architecture: IBM Z
→ Download: DVD ISO
```

Place it at the repo root or set `ISO_PATH`:

```bash
# Default expected location (relative to repo root):
ls RHEL-10.2-s390x-dvd1.iso

# Or set ISO_PATH to an arbitrary location:
export ISO_PATH=/path/to/RHEL-10.2-s390x-dvd1.iso
```

---

## 7. Stage 1 — Build the Base qcow2

### 7a. The problem with the current script

[`helpers/build-s390x-base-image.sh`](../../helpers/build-s390x-base-image.sh) calls:

```bash
virt-install \
    --virt-type kvm \       # ← BLOCKED on x86: no s390x KVM module
    --arch s390x \
    ...
```

On x86, the host KVM module only handles x86_64 guests. Attempting this produces:

```
ERROR   Cannot find suitable emulator for s390x
```

### 7b. The fix — patch the script

Apply this one-line change to [`helpers/build-s390x-base-image.sh`](../../helpers/build-s390x-base-image.sh):

```diff
-    --virt-type kvm \
+    --virt-type qemu \
+    --emulator /usr/bin/qemu-system-s390x \
```

Also remove `--cpu host-model` if it is present (CPU model pinning is meaningless in
software emulation — QEMU selects the s390x model automatically).

**Full patched `virt-install` block** (replace lines 183–196 in the script):

```bash
virt-install \
    --virt-type qemu \
    --emulator /usr/bin/qemu-system-s390x \
    --os-variant rhel10.2 \
    --arch s390x \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY_MB" \
    --location "$LOCATION" \
    --disk "path=${OUTPUT_DISK},format=qcow2,bus=virtio,size=${DISK_SIZE_GB}" \
    --initrd-inject "$KS_FILE" \
    --nographics \
    --noautoconsole \
    --wait -1 \
    --extra-args "console=ttysclp0 inst.ks=file:/rhel10-s390x-dm-root.ks inst.ks.org_id=${ORG_ID} inst.ks.activation_key=${ACTIVATION_KEY}" \
    --transient
```

### 7c. Run Stage 1

```bash
export ORG_ID="your-rhsm-org-id"
export ACTIVATION_KEY="your-rhsm-activation-key"

# Optional overrides (defaults shown):
export ISO_PATH="$(pwd)/RHEL-10.2-s390x-dvd1.iso"
export OUTPUT_DIR="$(pwd)/../output"
export OUTPUT_NAME="rhel10-s390x-base.qcow2"
export DISK_SIZE_GB=7
export VM_MEMORY_MB=8192

sudo -E bash helpers/build-s390x-base-image.sh
```

> **Expected runtime:** 1–3 hours on x86 software emulation.
> The console output will be silent for long periods while Anaconda runs package
> installation inside QEMU. This is normal — QEMU is running at ~5–10% of native
> speed for CPU-intensive operations like RPM scriptlets.

### 7d. What the script does internally (Stage 1)

```
build-s390x-base-image.sh
    │
    ├─ Validates ORG_ID, ACTIVATION_KEY, ISO_PATH, KS_FILE
    │
    ├─ Mounts/extracts the ISO to a temp dir
    │   (tries loop mount → bsdtar → 7z → pycdlib → isoinfo in order)
    │
    ├─ virt-install (qemu-system-s390x)
    │       │
    │       └─► boots s390x VM from ISO + kickstart
    │               │
    │               ├─ Anaconda partitions: vda1=PReP(100MiB) vda2=ext4(rest)
    │               ├─ Installs minimal RHEL 10 packages from DVD
    │               ├─ %post: fixes root GUID to s390x DPS GUID
    │               ├─ %post: registers with RHSM (ORG_ID + ACTIVATION_KEY)
    │               ├─ %post: dnf installs WALinuxAgent, afterburn, etc.
    │               ├─ %post: disables grub/dracut kernel-install hooks
    │               ├─ %post: version-locks s390utils-base
    │               ├─ %post: waagent deprovision (clears SSH keys, leases)
    │               └─ poweroff → VM exits
    │
    └─ Output: $OUTPUT_DIR/rhel10-s390x-base.qcow2
```

---

## 8. Verify the Base Image

```bash
OUTPUT_DISK="../output/rhel10-s390x-base.qcow2"

# 1. Confirm the file exists and has reasonable size
ls -lh "$OUTPUT_DISK"
# Expected: virtual size ~7G, actual on-disk ~800MiB-1.5GiB (qcow2 compressed)

# 2. Check image format
qemu-img info "$OUTPUT_DISK"
# Expected: file format: qcow2, virtual size: 7 GiB

# 3. Inspect partition layout via NBD
sudo modprobe nbd max_part=16
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 "$OUTPUT_DISK"
sleep 2
sudo lsblk -o NAME,PARTTYPE,SIZE,FSTYPE /dev/nbd1
# Expected:
#   nbd1       (disk)
#   nbd1p1     (PReP boot, 100MiB)
#   nbd1p2     (Linux fs, ~6.9GiB, ext4)
sudo qemu-nbd --disconnect /dev/nbd1

# 4. Confirm s390x root GUID was set by kickstart %post
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 "$OUTPUT_DISK"
sleep 2
sudo sfdisk -l /dev/nbd1 | grep -i "08a7acea"
# Expected: partition 2 shows GUID 08A7ACEA-624C-4A20-91E8-6E0FA67D23F9
sudo qemu-nbd --disconnect /dev/nbd1
```

---

## 9. Stage 2 — CoCo Components and dm-verity

### 9a. The problem — `virt-customize` appliance arch mismatch

[`coco-components-s390x.sh`](../../scripts/coco/coco-components-s390x.sh) and
[`verity-s390x.sh`](../../scripts/verity/verity-s390x.sh) both call `virt-customize`,
which internally uses `libguestfs`. On x86, libguestfs spins up an x86_64 "appliance" VM.
When that appliance mounts the s390x qcow2 and tries to run s390x binaries like `zipl`
or `dracut`, it gets `ENOEXEC` — the x86_64 kernel inside the appliance cannot execute
s390x ELF binaries.

```
virt-customize (x86 host)
    │
    └─► libguestfs launches appliance VM
              │
              └─► x86_64 kernel inside appliance
                        │
                        └─► exec("zipl")   ← s390x ELF
                                 │
                                 └─► ENOEXEC: Exec format error ✗
```

### 9b. The fix — `LIBGUESTFS_HV`

The environment variable `LIBGUESTFS_HV` overrides the hypervisor binary that libguestfs
uses to launch the appliance VM. Setting it to `qemu-system-s390x` makes libguestfs launch
an s390x appliance instead:

```bash
export LIBGUESTFS_HV=/usr/bin/qemu-system-s390x
```

```
virt-customize (x86 host, LIBGUESTFS_HV set)
    │
    └─► libguestfs launches appliance VM via qemu-system-s390x
              │
              └─► s390x kernel inside appliance
                        │
                        └─► qcow2 attached as /dev/vda (virtio-blk)
                                 │
                                 ├─► exec("zipl")   ← s390x ELF → runs ✓
                                 ├─► exec("dracut") ← s390x ELF → runs ✓
                                 └─► exec("dnf")    ← s390x ELF → runs ✓
```

**Critically for `zipl`:** the qcow2 is now a proper `virtio-blk` device (`/dev/vda`)
inside the appliance, not an NBD device. This means `zipl`'s block-level ioctls
(`HDIO_GETGEO`, `BLKGETSIZE64`, `BLKFLSBUF`) all work correctly and it can write the
bootmap with exact sector-level positioning.

### 9c. Set up LIBGUESTFS_HV and run Stage 2

```bash
# Tell libguestfs to use the s390x emulator as its appliance hypervisor
export LIBGUESTFS_HV=/usr/bin/qemu-system-s390x

# Also required: tell libguestfs to use the direct backend
# (Dockerfile.s390x already sets this; set it here too for host builds)
export LIBGUESTFS_BACKEND=direct

# RHSM credentials for re-subscription inside virt-customize
# (needed if script-disk-mods-s390x.sh needs to dnf install packages from RHSM)
export ACTIVATION_KEY="your-rhsm-activation-key"
export ORG_ID="your-rhsm-org-id"

INPUT_IMAGE="../output/rhel10-s390x-base.qcow2"

sudo -E bash scripts/create-verity-podvm-s390x.sh "$INPUT_IMAGE"
```

### 9d. What Stage 2 does internally

```
create-verity-podvm-s390x.sh  "$INPUT_IMAGE"
    │
    ├─ Detects image format (qcow2 → DISK_FORMAT=qcow2)
    │
    ├─ coco-components-s390x.sh  "$INPUT_IMAGE"
    │       │
    │       ├─ get-artifacts.sh
    │       │     podman pull → copies:
    │       │       podvm-binaries.tar.gz    (kata-agent, attestation-agent, etc.)
    │       │       pause-bundle.tar.gz
    │       │
    │       ├─ luks-scratch/build.sh  →  luks-config.tar.gz
    │       │
    │       ├─ virt-customize  [LIBGUESTFS_HV=qemu-system-s390x]
    │       │     --run script-disk-mods-s390x.sh
    │       │     --upload podvm-binaries.tar.gz → /tmp/
    │       │     --upload pause-bundle.tar.gz   → /tmp/
    │       │     --upload luks-config.tar.gz    → /tmp/
    │       │     --run podvm_maker-s390x.sh
    │       │
    │       │  Inside the s390x appliance VM (script-disk-mods-s390x.sh):
    │       │     ├─ Auto-detects kernel version from rpm
    │       │     ├─ dnf install pinned kernel packages
    │       │     ├─ Removes non-pinned kernels
    │       │     ├─ Patches parse-root.sh (veritysetup initqueue bypass)
    │       │     ├─ Patches systemd-volatile-root.service (overlay mode)
    │       │     ├─ Installs modprobe-overlay wrapper
    │       │     ├─ dracut --add systemd-veritysetup --add-drivers overlay
    │       │     ├─ Restores patched files
    │       │     └─ zipl --verbose  (updates bootmap for pinned kernel)
    │       │
    │       │  Inside the s390x appliance VM (podvm_maker-s390x.sh):
    │       │     ├─ dnf install afterburn e2fsprogs xmlsec1
    │       │     ├─ tar -x podvm-binaries, pause-bundle, luks-config
    │       │     ├─ Writes systemd unit files (afterburn, gen-issue, etc.)
    │       │     ├─ systemctl enable luks-scratch.service
    │       │     ├─ dnf remove cloud-init WALinuxAgent
    │       │     └─ firewall-offline-cmd --add-port=15150/tcp
    │       │
    │       └─ virt-customize  [LIBGUESTFS_HV=qemu-system-s390x]
    │             --run-command "subscription-manager unregister"
    │
    └─ verity-s390x.sh  "$INPUT_IMAGE"
            │
            ├─ qemu-img info  → reads disk size (x86 native tool)
            ├─ qemu-img resize → adds space for LUKS + verity partitions
            │
            ├─ modprobe nbd
            ├─ qemu-nbd -c /dev/nbd0 → attaches qcow2 as block device
            │
            ├─ find_root_part()   → lsblk PARTTYPE (x86 native)
            ├─ call_fsck()        → fsck.ext4 -y (x86 native)
            │
            ├─ create_verity_partition()
            │     systemd-repart → adds GPT entry for verity hash partition
            │     (x86 native tool — just writes GPT table to the image file)
            │
            ├─ patch_bls_and_run_zipl()
            │     ├─ mount /dev/nbd0p2 → patch BLS *.conf files (sed)
            │     │   Adds: root=/dev/mapper/root
            │     │         systemd.volatile=overlay
            │     │         rd.driver.pre=overlay
            │     │   Strips: inst.ks.* installer args
            │     │
            │     ├─ qemu-nbd --disconnect   (x86 native)
            │     │
            │     ├─ virt-customize  [LIBGUESTFS_HV=qemu-system-s390x]
            │     │     --run-command 'zipl --verbose'
            │     │     --selinux-relabel
            │     │   (bakes clean BLS cmdline into /boot/bootmap)
            │     │
            │     └─ qemu-nbd -c /dev/nbd0  (reconnect for veritysetup)
            │
            └─ compute_roothash()
                  veritysetup format DATA_DEV HASH_DEV  (x86 native)
                  → prints + saves roothash to .qcow2.roothash sidecar file
```

### 9e. Expected output

```bash
ls -lh ../output/
# rhel10-s390x-base.qcow2          ← final dm-verity protected image
# rhel10-s390x-base.qcow2.roothash ← 64-char hex string, needed at VM boot time

cat ../output/rhel10-s390x-base.qcow2.roothash
# e.g.: a3f1c8b2d4e6...  (64 hex chars)
```

---

## 10. Verify the Final Image

### 10a. Partition layout

```bash
OUTPUT_DISK="../output/rhel10-s390x-base.qcow2"

sudo modprobe nbd max_part=16
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 "$OUTPUT_DISK"
sleep 2

sudo lsblk -o NAME,SIZE,FSTYPE,PARTTYPE /dev/nbd1
# Expected:
#   nbd1p1  100M                 (PReP boot)
#   nbd1p2  ~7G    ext4          (root, dm-verity data partition)
#   nbd1p3  ~500M                (verity hash partition)
#   nbd1p4  ~2.5G               (LUKS scratch partition)

sudo qemu-nbd --disconnect /dev/nbd1
```

### 10b. BLS boot entry has correct cmdline

```bash
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 "$OUTPUT_DISK"
sleep 2
sudo mount -o ro /dev/nbd1p2 /tmp/verity-check
sudo grep "options" /tmp/verity-check/boot/loader/entries/*.conf | grep -v rescue
# Expected line contains:
#   root=/dev/mapper/root  systemd.volatile=overlay  rd.driver.pre=overlay
# Expected line does NOT contain:
#   inst.ks  (kickstart args stripped)
#   roothash= (NOT in bootmap — supplied at VM start time)
sudo umount /tmp/verity-check
sudo qemu-nbd --disconnect /dev/nbd1
```

### 10c. veritysetup dump confirms hash tree

```bash
sudo modprobe nbd max_part=16
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 "$OUTPUT_DISK"
sleep 2

sudo veritysetup dump /dev/nbd1p2 /dev/nbd1p3
# Expected: shows Hash type: 1, Data blocks: NNNN, Salt: ..., Root hash: <64 hex chars>

ROOTHASH=$(cat "$OUTPUT_DISK.roothash")
sudo veritysetup verify /dev/nbd1p2 /dev/nbd1p3 "$ROOTHASH"
# Expected: no output = verification passed

sudo qemu-nbd --disconnect /dev/nbd1
```

---

## 11. Troubleshooting

### Problem: `ERROR Cannot find suitable emulator for s390x`

**Cause:** `virt-install` cannot find `qemu-system-s390x`.

**Fix:**
```bash
sudo dnf install qemu-system-s390x
ls /usr/bin/qemu-system-s390x   # must exist
sudo systemctl restart libvirtd
```

### Problem: `virt-install` exits immediately with `--virt-type qemu` errors

**Cause:** `--os-variant rhel10.2` may not be in the osinfo database on older distros.

**Fix:**
```bash
sudo dnf install osinfo-db osinfo-db-tools
# or override:
--os-variant rhel9.0   # closest available variant
```

### Problem: `virt-customize` exits with `ENOEXEC` or `Exec format error`

**Cause:** `LIBGUESTFS_HV` is not set — libguestfs is using the x86_64 appliance.

**Fix:**
```bash
export LIBGUESTFS_HV=/usr/bin/qemu-system-s390x
export LIBGUESTFS_BACKEND=direct
```

Confirm it is picked up:
```bash
sudo -E env | grep LIBGUESTFS
```

### Problem: `supermin: failed to find a suitable kernel` or appliance build fails

**Cause:** libguestfs needs an s390x kernel to build/run the appliance. The
`libguestfs-appliance` package provides this on Fedora.

**Fix:**
```bash
sudo dnf install libguestfs-appliance
# Or force a rebuild:
sudo LIBGUESTFS_HV=/usr/bin/qemu-system-s390x \
     libguestfs-test-tool 2>&1 | tail -20
```

### Problem: `zipl: Error: Could not get disk geometry` inside chroot

**Cause:** You are trying to run `zipl` via a `chroot` over NBD. This is expected to
fail (see [Section 12](#12-why-these-fixes-work) for the full explanation). `zipl` must
run via `virt-customize` with `LIBGUESTFS_HV` set.

### Problem: `veritysetup verify` fails after build

**Cause:** Something wrote to the root partition after `veritysetup format` ran —
possibly a second `virt-customize` call. The hash tree covers the exact byte state of
the partition at the time `veritysetup format` was called.

**Fix:** Re-run from `verity-s390x.sh` only (do not re-run CoCo components):
```bash
export LIBGUESTFS_HV=/usr/bin/qemu-system-s390x
export LIBGUESTFS_BACKEND=direct
export DISK_FORMAT=qcow2
bash scripts/verity/verity-s390x.sh ../output/rhel10-s390x-base.qcow2
```

### Problem: Stage 1 `virt-install` hangs indefinitely

**Cause:** Anaconda on s390x requires `inst.cmdline` and `inst.text` to avoid waiting
for interactive input on VNC. The current `build-s390x-base-image.sh` does not pass
these. If you see no console progress after 15 minutes, add them.

**Fix:** Add to `--extra-args` in the script:
```
inst.cmdline inst.text
```

### Problem: `qemu-nbd` cannot find `/dev/nbd0`

**Cause:** `nbd` kernel module is not loaded.

**Fix:**
```bash
sudo modprobe nbd max_part=16
lsmod | grep nbd   # should show the module loaded
```

---

## 12. Why These Fixes Work (Deep-dive)

### Why `--virt-type qemu --emulator qemu-system-s390x` works

`virt-install` is a frontend for `libvirt`. When `--virt-type kvm` is requested, libvirt
looks for `/dev/kvm` on the host and opens it to create an s390x KVM domain — but the
x86 host only has an x86_64 KVM module. With `--virt-type qemu`, libvirt uses pure
software emulation via the specified `--emulator` binary. `qemu-system-s390x` contains
a complete cycle-accurate s390x CPU simulator. Every s390x instruction is translated
to x86 at runtime (TCG — Tiny Code Generator). The emulated machine is identical to a
real s390x from the guest's perspective: same instruction set, same device layout, same
firmware. The kickstart, Anaconda, `zipl`, and all package scriptlets run without
modification.

### Why `LIBGUESTFS_HV` works for `virt-customize`

`libguestfs` works by:
1. Building a minimal Linux system ("the appliance") via `supermin`
2. Booting that appliance inside a hypervisor VM
3. Communicating with it over a virtio serial port
4. Asking it to run your `--run-command` scripts inside the target disk

On x86 without `LIBGUESTFS_HV`, the appliance is built for and booted on x86_64.
The target qcow2's root partition is attached as `/dev/sda` inside that x86_64 VM.
When a script tries to `exec("/usr/sbin/zipl")`, the x86_64 kernel reads the ELF
header, sees `e_machine = EM_S390`, and returns `ENOEXEC`.

With `LIBGUESTFS_HV=/usr/bin/qemu-system-s390x`, libguestfs boots the appliance
inside an s390x software-emulated machine. The appliance kernel is now s390x. The
target qcow2 is attached as `/dev/vda` (virtio-blk). When `zipl` runs, the s390x
kernel inside the appliance executes it natively — and `zipl` sees `/dev/vda` as a
proper virtio-blk device, so all block ioctls (`HDIO_GETGEO`, `BLKGETSIZE64`,
`BLKFLSBUF`) return correct values.

### Why `binfmt_misc` + chroot cannot replace `virt-customize` for `zipl`

`binfmt_misc` is a Linux kernel facility that intercepts `execve()` for non-native
ELF binaries and routes them through a registered interpreter (e.g.
`qemu-s390x-static`). This works for filesystem-level operations:

```
chroot /mnt/guest dracut ...
    │
    └─► x86 kernel intercepts exec("dracut") [EM_S390]
             │
             └─► qemu-s390x-static /usr/bin/dracut
                      │
                      └─► dracut reads/writes files → all VFS calls → works ✓
```

But `zipl` is different. After opening the block device, it calls:

```c
ioctl(fd, HDIO_GETGEO, &geo);   // get disk geometry (cylinders, heads, sectors)
```

Over an NBD device (`/dev/nbd0`), this ioctl returns `EINVAL` because NBD is a
network protocol wrapper — it exposes a block device but does not emulate disk
geometry. The NBD driver simply has no implementation for `HDIO_GETGEO`. `zipl`
treats `EINVAL` from this ioctl as a fatal error and aborts.

`virt-customize` with `LIBGUESTFS_HV=qemu-system-s390x` solves this because the
qcow2 is presented to `zipl` as a `virtio-blk` device. QEMU's virtio-blk emulation
implements `HDIO_GETGEO` by deriving geometry from the disk size (the same heuristic
a real disk controller uses). `zipl` gets a valid geometry and proceeds.

This is why the existing `verity-s390x.sh` already implements the
disconnect-NBD → virt-customize zipl → reconnect-NBD pattern at lines 389–436: it is
the correct, tested solution. Setting `LIBGUESTFS_HV` is the only change needed to
make that same pattern work on x86.
