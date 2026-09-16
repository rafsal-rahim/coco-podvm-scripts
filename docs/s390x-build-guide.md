# s390x CoCo PodVM Image Build — Developer Guide

This document explains every file created for the s390x build pipeline,
how they relate to one another, and every error that was encountered and
resolved during the first real build run.

---

## Table of Contents

1. [Overview — what the build does](#1-overview)
2. [Architecture differences vs x86_64](#2-architecture-differences-vs-x8664)
3. [Files created](#3-files-created)
4. [Build pipeline — end-to-end flow](#4-build-pipeline--end-to-end-flow)
5. [Errors encountered and resolved](#5-errors-encountered-and-resolved)
6. [How to run a full build](#6-how-to-run-a-full-build)

---

## 1. Overview

The goal is to produce a dm-verity protected CoCo (Confidential Containers)
PodVM disk image for IBM Z (s390x), following the same overall pattern as
the existing x86_64 pipeline:

```
RHEL 10 ISO  ──►  base disk image  ──►  CoCo components  ──►  dm-verity  ──►  final image
               (virt-install + KS)     (virt-customize)       (systemd-repart
                                                               + zipl)
```

The s390x pipeline is a parallel set of scripts — it does **not** modify any
existing x86_64 file. Both can coexist in the same repo.

---

## 2. Architecture differences vs x86_64

These differences drive every design decision in the s390x scripts.

| Concern | x86_64 | s390x |
|---|---|---|
| Boot firmware | UEFI + shim + EFI System Partition | **zipl** bootloader + PReP boot partition |
| Boot record update | `BOOTX64.CSV` written by kernel-install | `zipl --verbose` writes to PReP partition |
| UKI / addon | `kernel-uki-virt` + `ukify` + `.extra.d/verity.addon.efi` | **Does not exist on s390x** — plain `kernel` + BLS entries |
| Roothash delivery | UKI addon placed in ESP | Appended to `options` line in `/boot/loader/entries/*.conf`, then `zipl` re-run |
| Root partition GUID | `4f68bce3-e8cd-4db1-96e7-fbcaf984b709` | `08a7acea-624c-4a20-91e8-6e0fa67d23f9` |
| `systemd-repart` verity type | `root-x86-64-verity` | `root-s390x-verity` |
| Disk device in guest | `sda` (SCSI) | `vda` (virtio-blk) |
| Serial console | `ttyS0` | `ttysclp0` (IBM Z line-mode console) |
| Secure Boot signing | `sbsigntools` + `SB_PRIVATE_KEY` | Not applicable (IBM Secure Execution uses a different trust chain) |
| NVIDIA drivers | Available | Not applicable (NVIDIA has no s390x drivers) |
| `kernel-uki-virt` package | Available on RHEL 10 x86_64 | **Does not exist** on RHEL 10 s390x |
| Build host requirement | Any x86_64 KVM host | Must be a native **s390x KVM host** |

---

## 3. Files created

### 3.1 `helpers/rhel10-s390x-dm-root.ks`

**What it is:** Anaconda kickstart file for the base OS install.

**What it does:**

- Installs a minimal RHEL 10 s390x system from the DVD ISO.
- Creates the correct s390x partition layout:
  - `vda1` — 4 MiB PReP boot partition (required by `zipl`)
  - `vda2` — ext4 root (grows to fill disk)
- In `%post`:
  1. Sets the s390x Discoverable Partitions Spec GUID (`08A7ACEA-…`) on `vda2`
     via `sfdisk --part-type` so `systemd-repart` can find it later.
  2. Reads `ORG_ID` and `ACTIVATION_KEY` from `/proc/cmdline`
     (injected by `build-s390x-base-image.sh`) and registers with RHSM.
  3. Installs packages not available on the DVD:
     `WALinuxAgent`, `cloud-utils-growpart`, `NetworkManager-cloud-setup`,
     `kernel-modules-extra`, `afterburn`, `python3-dnf-plugin-versionlock`.
  4. Enables those services (`waagent`, `nm-cloud-setup`, `cloud-init`).
  5. Unregisters RHSM so the image carries no active entitlement.
  6. Runs `waagent -force -deprovision` to clear SSH host keys and DHCP leases.
  7. Runs `fstrim` to reclaim unused blocks.
- Ends with `poweroff` so `virt-install --wait -1` unblocks automatically.

**Key s390x-specific lines:**
```
ignoredisk --only-use=vda
part prepboot  --fstype="prepboot" --ondisk=vda --size=4
part /         --fstype="ext4"     --ondisk=vda --grow
sfdisk --part-type /dev/vda 2 08A7ACEA-624C-4A20-91E8-6E0FA67D23F9
```

---

### 3.2 `helpers/build-s390x-base-image.sh`

**What it is:** Fully automated `virt-install` wrapper. Replaces any need
for manual intervention during the base OS install.

**What it does:**

- Validates `ORG_ID` and `ACTIVATION_KEY` are set before starting.
- Removes any leftover output disk from a previous failed run.
- Runs `virt-install` with flags that eliminate all interactive prompts:
  - `--noautoconsole` — suppresses the "no TTY" warning; does not try to attach a console.
  - `--wait -1` — blocks until the VM shuts off (kickstart `poweroff`).
  - `--transient` — domain is automatically undefined on shutdown; no cleanup needed.
- Passes `ORG_ID` and `ACTIVATION_KEY` into the kickstart via kernel cmdline:
  ```
  inst.ks.org_id=<ORG_ID>  inst.ks.activation_key=<KEY>
  ```
  Anaconda preserves all `inst.ks.*` parameters in the kernel cmdline, making
  them readable inside `%post` via `/proc/cmdline`.
- Installs a trap so the VM is destroyed on Ctrl-C or any script error.
- Prints the final disk path and size on success.

**Usage:**
```bash
export ORG_ID=<YOUR_ORG_ID>
export ACTIVATION_KEY=<YOUR_ACTIVATION_KEY>
helpers/build-s390x-base-image.sh
```

---

### 3.3 `scripts/coco/podvm/script-disk-mods-s390x.sh`

**What it is:** Runs inside the target disk via `virt-customize`. Pins the
kernel to a specific version and prepares the boot chain.

**What it does:**

- Installs pinned kernel packages (`kernel`, `kernel-core`, `kernel-modules`,
  `kernel-modules-core`, `kernel-modules-extra`) for `KERNEL_VERSION`.
- Removes any kernel packages that do not match `KERNEL_VERSION`.
- Runs `dracut --force` to regenerate the initramfs for the pinned kernel.
- Runs `zipl --verbose` to update the PReP boot record.
- Installs `xmlsec1` and `xmlsec1-openssl` (needed by the CoCo attestation flow).

**Why this differs from x86_64:**
- No `kernel-uki-virt` — that package does not exist on RHEL 10 s390x.
- No `BOOTX64.CSV` update — there is no EFI shim on s390x.
- No NVIDIA driver installation — NVIDIA has no s390x drivers.
- `zipl --verbose` replaces the shim CSV update.

---

### 3.4 `scripts/coco/podvm/podvm_maker-s390x.sh`

**What it is:** Runs inside the target disk via `virt-customize`. Installs
and configures all CoCo guest components.

**What it does:**

- Installs `afterburn` and `e2fsprogs` (idempotently — they may already be present).
- Configures `afterburn-checkin.service` for Azure provider check-in.
- Extracts CoCo payload tarballs (`podvm-binaries`, `pause-bundle`, `luks-config`).
- Removes `cloud-init` and `WALinuxAgent` (replaced by `kata-agent`).
- Fixes the SELinux label for `/usr/bin/ip` (`semanage fcontext`).
- Enables `luks-scratch.service` (LUKS encrypted scratch partition for kata-agent).
- Creates and enables `gen-issue.service` to print vTPM PCR values at boot.
  Uses `serial-getty@ttysclp0.service` as the dependency (not `ttyS0`).
- Creates `process-user-data.service.d/10-override.conf` to extend PCR8
  with the initdata digest.
- Opens firewall port 15150/tcp (required for CoCo networking).

**Key s390x change:** all references to `ttyS0` are replaced with `ttysclp0`.

---

### 3.5 `scripts/coco/coco-components-s390x.sh`

**What it is:** Orchestrator for the CoCo component installation step.
Mirrors `coco-components.sh` but calls the s390x-specific scripts.

**What it does:**

- Downloads CoCo payload artefacts from the registry (`get-artifacts.sh`).
- Builds `luks-config.tar.gz` from `luks-scratch/`.
- Calls `virt-customize` with:
  - `script-disk-mods-s390x.sh` (kernel pinning, zipl, xmlsec1)
  - `podvm_maker-s390x.sh` (CoCo components, service configuration)
- Handles optional RHSM registration/unregistration via `ACTIVATION_KEY` + `ORG_ID`.

---

### 3.6 `scripts/verity/verity-s390x.sh`

**What it is:** Applies dm-verity to the s390x disk image.
Mirrors `verity.sh` but replaces the entire EFI/UKI addon mechanism.

**What it does:**

1. Optionally resizes the disk (+2500 MiB for LUKS scratch, +7% for verity hash).
2. Connects the disk via `qemu-nbd`.
3. Finds the root partition by the s390x GUID (`08a7acea-…`).
4. Runs `fsck` on the root partition.
5. Creates the verity hash partition using `systemd-repart`.
   Filters the JSON output on `root-s390x-verity` (not `root-x86-64-verity`).
6. **`inject_roothash_zipl()`** — replaces `create_uki_addon()`:
   - Mounts the root partition.
   - Patches every BLS entry (`/boot/loader/entries/*.conf`) by appending
     `roothash=<RH> systemd.volatile=overlay` to the `options` line.
   - Runs `chroot … zipl --verbose` to commit the updated boot record.
   - Unmounts cleanly.

**Default `ROOT_PARTITION_UUID`:** `08a7acea-624c-4a20-91e8-6e0fa67d23f9`

---

### 3.7 `scripts/create-verity-podvm-s390x.sh`

**What it is:** Top-level entry point for the CoCo + verity pipeline.
Mirrors `create-verity-podvm.sh` but wires up the s390x scripts.

**What it does:**

- Detects the input image format (`qcow2` / `raw` / `vpc`).
- Calls `coco-components-s390x.sh` to install CoCo components.
- Calls `verity-s390x.sh` to apply dm-verity.
- Cleans up the work folder on completion.

**Usage:**
```bash
scripts/create-verity-podvm-s390x.sh /path/to/rhel10-s390x-base.qcow2
```

---

### 3.8 `Dockerfile.s390x`

**What it is:** Container image for running the full CoCo + verity pipeline
inside a container (mirrors the existing `Dockerfile` for x86_64).

**Differences from `Dockerfile`:**
- No `systemd-ukify` — UKI addons are not used on s390x.
- No `sbsigntools` — EFI Secure Boot signing is not applicable on s390x.
- Uses `guestfs-tools libguestfs libguestfs-appliance` (correct RHEL 10 package names,
  replacing the broken `libguestfs-tools` name from the x86_64 Dockerfile).

---

### 3.9 `helpers/rhel10-s390x-dm-root.md`

End-to-end usage guide: architecture comparison table, step-by-step build
instructions, environment variable reference, and troubleshooting section.

---

### 3.10 `helpers/s390x-build-readiness.md`

System pre-flight checklist generated after running a full host inspection.
Documents which tools are present, which are correctly absent on s390x, and
the two items that needed remediation (ISO file, Dockerfile package name).

---

## 4. Build pipeline — end-to-end flow

```
helpers/build-s390x-base-image.sh
  │
  │  virt-install (--noautoconsole --wait -1 --transient)
  │  RHEL 10 s390x DVD ISO  +  rhel10-s390x-dm-root.ks
  │
  ▼
output/rhel10-s390x-base.qcow2          ← base OS disk
  │
  │  scripts/create-verity-podvm-s390x.sh
  │
  ├─► coco-components-s390x.sh
  │     ├─ get-artifacts.sh             pull CoCo payload from registry
  │     ├─ luks-scratch/build.sh        build luks-config.tar.gz
  │     └─ virt-customize
  │           ├─ script-disk-mods-s390x.sh   pin kernel, zipl, xmlsec1
  │           └─ podvm_maker-s390x.sh        CoCo services, afterburn, SELinux
  │
  └─► verity-s390x.sh
        ├─ qemu-nbd attach
        ├─ fsck root partition
        ├─ systemd-repart  →  verity hash partition  →  roothash
        ├─ patch BLS entries  (options += roothash=… systemd.volatile=overlay)
        └─ chroot zipl --verbose
  │
  ▼
output/rhel10-s390x-base.qcow2          ← dm-verity protected CoCo PodVM image
```

---

## 5. Errors encountered and resolved

These are all the errors hit during the first real build run and the exact
fixes applied to the scripts so they do not recur.

---

### Error 1 — `virt-install` warning: "Cannot run interactive console without a controlling TTY"

**What happened:**
Running `virt-install` from a non-interactive shell (no TTY) caused it to
print a warning and try to open a console session that immediately failed.
The VM itself continued running but there was no way to observe progress.

**Root cause:** `virt-install` defaults to attaching a console (`--autoconsole text`)
which requires a TTY.

**Fix — `helpers/build-s390x-base-image.sh`:**
```bash
--noautoconsole   # do not attempt to attach console
--wait -1         # block until VM shuts off (replaces console monitoring)
```

---

### Error 2 — Anaconda hub blocked at interactive `yes/no` prompt (kdump)

**What happened:**
After package installation, Anaconda's text hub paused at:
```
Please respond 'yes' or 'no':
```
The kdump addon (`%addon com_redhat_kdump --enable`) triggered an interactive
dialog asking whether to enable crash dumps. This blocked the unattended install.

**Fix — `helpers/rhel10-s390x-dm-root.ks`:**
```
%addon com_redhat_kdump --disable
%end
```

---

### Error 3 — `WALinuxAgent` and `kernel-uki-virt` not found on DVD

**What happened:**
Anaconda reported:
```
missing packages: WALinuxAgent, kernel-uki-virt
Would you like to ignore this and continue with installation?
```
The DVD ISO does not carry `WALinuxAgent` or `kernel-uki-virt`; they live
in RHSM network repositories.

**Fix — `helpers/rhel10-s390x-dm-root.ks`:**

Moved all network-only packages out of `%packages` and into a `dnf install`
inside `%post`, which runs after the network is up:
```bash
dnf install -y WALinuxAgent cloud-utils-growpart NetworkManager-cloud-setup \
    kernel-modules-extra afterburn python3-dnf-plugin-versionlock
```

---

### Error 4 — `kernel-uki-virt` does not exist on RHEL 10 s390x

**What happened:**
Even after moving to `%post`, `dnf install kernel-uki-virt` failed:
```
No match for argument: kernel-uki-virt
```
The `kernel-uki-virt` package (Unified Kernel Image for virtual machines)
is an x86_64/aarch64 concept and is not published for s390x. On IBM Z,
the standard `kernel` package is used together with `zipl`.

**Fix — `helpers/rhel10-s390x-dm-root.ks` and `scripts/coco/podvm/script-disk-mods-s390x.sh`:**

Removed `kernel-uki-virt` from all package lists. In `script-disk-mods-s390x.sh`,
replaced it with explicit s390x kernel package names:
```bash
dnf install -y \
    kernel-${KERNEL_VERSION} \
    kernel-core-${KERNEL_VERSION} \
    kernel-modules-${KERNEL_VERSION} \
    kernel-modules-core-${KERNEL_VERSION} \
    kernel-modules-extra-${KERNEL_VERSION}
```

---

### Error 5 — `services` kickstart directive rejected unknown service names

**What happened:**
The kickstart line:
```
services --enabled="sshd,NetworkManager,nm-cloud-setup.service,nm-cloud-setup.timer,
                   cloud-init,cloud-init-local,cloud-config,cloud-final,waagent"
```
failed because `waagent`, `nm-cloud-setup`, and several `cloud-*` services
do not exist in the DVD-installed system — they are installed later in `%post`.
Anaconda either rejected the line or silently failed to enable them.

**Fix — `helpers/rhel10-s390x-dm-root.ks`:**

The `services` directive now only enables what exists post-DVD install:
```
services --enabled="sshd,NetworkManager"
```
All other services are enabled via `systemctl enable` in `%post` after
the packages are installed.

---

### Error 6 — RHSM not registered inside `%post` — `dnf install` found no repos

**What happened:**
Inside the installer's `%post`, `dnf` reported:
```
Error: There are no enabled repositories in "/etc/yum.repos.d"
```
The installer environment has no RHSM subscription and no repo files.

**Fix — `helpers/rhel10-s390x-dm-root.ks` + `helpers/build-s390x-base-image.sh`:**

`build-s390x-base-image.sh` passes credentials on the kernel cmdline:
```bash
--extra-args "... inst.ks.org_id=${ORG_ID} inst.ks.activation_key=${ACTIVATION_KEY}"
```
The kickstart `%post` reads them from `/proc/cmdline` and registers:
```bash
ORG_ID=$(sed -n 's/.*inst\.ks\.org_id=\([^ ]*\).*/\1/p' /proc/cmdline)
ACTIVATION_KEY=$(sed -n 's/.*inst\.ks\.activation_key=\([^ ]*\).*/\1/p' /proc/cmdline)
subscription-manager register --org="$ORG_ID" --activationkey="$ACTIVATION_KEY"
```
At the end of `%post` it unregisters so the image carries no active entitlement.

---

### Error 7 — Anaconda Python crash dropped to shell instead of powering off

**What happened:**
After the package installation completed, Anaconda hit a Python exception in
`installation_progress.py`:
```
File ".../pyanaconda/ui/tui/spokes/installation_progress.py", line 126,
in _on_installation_done
```
Instead of running `%post` and issuing `poweroff`, it dropped to a
`bash-5.2#` shell inside the installer environment.

**What was done manually (and is now automated):**
- Set the s390x root partition GUID via `sfdisk --part-type`
- Bind-mounted `dev/proc/sys/run` into `/mnt/sysroot`
- Registered RHSM inside the chroot
- Installed all missing packages via `dnf` in the chroot
- Enabled services with `systemctl enable`
- Ran `zipl --verbose` inside the chroot
- Ran `waagent -force -deprovision`
- Unmounted bind mounts and issued `poweroff`

**Fix:** All of the above steps are now encoded in `%post --erroronfail` with
`set -ex`, so they run inside Anaconda's own `%post` phase before the crash
point in `installation_progress.py`. The kickstart `poweroff` directive
ensures shutdown regardless of the UI crash.

---

### Error 8 — `vda2` had wrong partition GUID after install

**What happened:**
After the base install completed, inspection showed:
```
vda2  ext4  0fc63daf-8483-4772-8e79-3d69d8477de4   ← generic Linux data
```
instead of:
```
vda2  ext4  08a7acea-624c-4a20-91e8-6e0fa67d23f9   ← s390x root (DPS)
```
`systemd-repart` in `verity-s390x.sh` searches for the root partition by
its type GUID. With the wrong GUID it would fail to find it.

**Root cause:** Anaconda sets a generic "Linux data" GUID regardless of the
`prepboot` + `ext4` partition scheme.

**Fix — `helpers/rhel10-s390x-dm-root.ks`:**
```bash
sfdisk --part-type /dev/vda 2 08A7ACEA-624C-4A20-91E8-6E0FA67D23F9
```
This is the first command in `%post` so it runs before anything else.

---

### Error 9 — `libguestfs-tools` package name does not exist on RHEL 10

**What happened:**
`Dockerfile.s390x` had:
```
RUN dnf install -y guestfs-tools libguestfs-tools && dnf clean all
```
`libguestfs-tools` is the old RHEL 9 name. On RHEL 10 it was renamed and
split; the correct packages are `guestfs-tools` + `libguestfs` + `libguestfs-appliance`.

**Fix — `Dockerfile.s390x`:**
```
RUN dnf install -y guestfs-tools libguestfs libguestfs-appliance && dnf clean all
```

---

### Error 10 — `script-disk-mods-s390x.sh` failed: hardcoded `KERNEL_VERSION` not present in image

**What happened:**
The script had `KERNEL_VERSION=6.12.0-211.16.1.el10_2` hardcoded. The base
image built from the RHSM network repo had `6.12.0-211.53.1.el10_2.s390x`
(a newer kernel pulled during `%post`). The `dracut` call failed:
```
dracut[F]: /usr/lib/modules/6.12.0-211.16.1.el10_2.s390x/modules.dep is missing.
```
This left the image with only the rescue kernel BLS entry, causing
`systemd-repart` to output `roothash: TBD` (no writable root data partition
to hash against).

**Fix — `scripts/coco/podvm/script-disk-mods-s390x.sh`:**

`KERNEL_VERSION` is now auto-detected from the guest at runtime if not
explicitly set:
```bash
if [[ -z "${KERNEL_VERSION:-}" ]]; then
    KERNEL_VERSION=$(rpm -q kernel-core \
        --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | sort -V | tail -1)
fi
```
A specific version can still be pinned by exporting `KERNEL_VERSION` before
calling `create-verity-podvm-s390x.sh`.

---

### Error 11 — initramfs missing `systemd-veritysetup` module → verity device never assembled

**What happened:**
The image built and passed all static checks, but the VM stalled in the initramfs
at every boot attempt. QEMU register inspection confirmed the kernel had reached
userspace (udev running), but `/dev/mapper/root` was never assembled and the boot
stalled silently.

**Root cause — two independent sub-issues, both required to boot:**

**Sub-issue A — `--add systemd-veritysetup` missing from the `dracut` call.**
`dracut` does not auto-include the `systemd-veritysetup` module unless `roothash=`
is already present in the running kernel cmdline. Since verity is applied *after*
initramfs generation (`verity-s390x.sh` runs next), the module is absent from the
initramfs. At boot, `systemd-veritysetup-generator` is not present, so no
`systemd-veritysetup@root.service` is ever generated, and `/dev/mapper/root` is
never assembled.

**Sub-issue B — `parse-root.sh` deadlock: `systemd-veritysetup` missing from the
`dracut-initqueue` bypass.**
`dracut-107` (RHEL 10.2) `parse-root.sh` writes a finished-hook script that
blocks `dracut-initqueue` until `[ -e /dev/mapper/root ]`. The bypass condition
only exempts `systemd-cryptsetup@*.service`. But `remote-veritysetup.target` is
declared `After=remote-fs-pre.target`, which only starts *after* `dracut-initqueue`
exits. Result: `dracut-initqueue` waits for `/dev/mapper/root`; `systemd-veritysetup`
waits for `dracut-initqueue`. Deadlock — confirmed in the old repo's QEMU debug logs.

**Diagnosis source:**
Identified by cross-referencing the old repo (`support-s390x-podvm-image`) debug
logs in `s390x-debug-logs/qemu-registers-boot-debug.txt` and
`s390x-debug-logs/initramfs-verity.txt`, and confirmed by inspecting the host
`parse-root.sh` directly.

**Fix — `scripts/coco/podvm/script-disk-mods-s390x.sh`:**

```bash
# Patch parse-root.sh to add veritysetup bypass (identical to existing cryptsetup bypass)
PARSE_ROOT=/usr/lib/dracut/modules.d/98dracut-systemd/parse-root.sh
cp -p "$PARSE_ROOT" "${PARSE_ROOT}.orig"
sed -i \
    's|grep -q After=remote-fs-pre\.target /run/systemd/generator/systemd-cryptsetup@\*\.service 2>/dev/null|& \&\& ! grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-veritysetup@*.service 2>/dev/null|' \
    "$PARSE_ROOT"

# Build initramfs — must include systemd-veritysetup explicitly
dracut --force --kver "${KERNEL_VERSION}.s390x" --add "systemd-veritysetup"

# Restore parse-root.sh so the host system is unchanged
mv "${PARSE_ROOT}.orig" "$PARSE_ROOT"
```

The `sed` pattern appends the `veritysetup` check to line 29 of `parse-root.sh`,
producing:
```bash
if ! grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-cryptsetup@*.service 2>/dev/null \
&& ! grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-veritysetup@*.service 2>/dev/null; then
    [ -e "$root_dev" ]
fi
```

The `sed` approach (not a full file replace) is intentional: if dracut is updated
and the upstream file gains the `veritysetup` bypass, the `sed` pattern will
match the already-patched line and the `grep` verification step will confirm it
is already correct.

---

## 6. How to run a full build

### Step 1 — Build the base OS image (automated)

```bash
export ORG_ID=<your-rhsm-org-id>
export ACTIVATION_KEY=<your-activation-key>

# Optional:
# export ISO_PATH=/path/to/RHEL-10.2-s390x-dvd1.iso
# export OUTPUT_DIR=/path/to/output

helpers/build-s390x-base-image.sh
# Output: ../output/rhel10-s390x-base.qcow2
```

### Step 2 — Apply CoCo components and dm-verity

```bash
export PODVM_BINARY=quay.io/...      # optional — defaults are set in coco-components-s390x.sh
export PAUSE_BUNDLE=quay.io/...      # optional

scripts/create-verity-podvm-s390x.sh ../output/rhel10-s390x-base.qcow2
```

### Step 3 — (Optional) Build and run via the container

```bash
# Build the container (on s390x host)
sudo podman build -t coco-podvm-s390x -f Dockerfile.s390x .

# Run it
sudo podman run --rm --privileged \
    -v ../output/rhel10-s390x-base.qcow2:/disk.qcow2 \
    -v /lib/modules:/lib/modules:ro,Z \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    localhost/coco-podvm-s390x
```

---

## 7. First successful automated build — observations

This section records what was observed during the **first fully automated
build run** (9 Sep 2026) where `helpers/build-s390x-base-image.sh` completed
without any manual intervention. These are not errors — they are expected
behaviours worth understanding.

---

### Observation 1 — Multiple kernel versions in the output image

**What was seen:**
After `%post` completed, the image contained **two kernel versions**:

| Package | Source |
|---|---|
| `kernel-modules-extra-6.12.0-211.7.3.el10_2.s390x` | DVD ISO (installed by Anaconda) |
| `kernel-modules-extra-6.12.0-211.53.1.el10_2.s390x` | RHSM network repo (installed by `%post` `dnf install`) |

The BLS entries directory therefore contained three entries:
- `…0-rescue-….conf` — rescue kernel
- `…6.12.0-211.7.3.el10_2.s390x.conf` — DVD kernel
- `…6.12.0-211.53.1.el10_2.s390x.conf` — latest RHSM kernel

**Why this happens:**
The `%post` `dnf install kernel-modules-extra` step pulls the **latest
available version** from RHSM, which may be newer than what the DVD shipped.
`dnf` also pulls in the matching `kernel` and related packages automatically.

**Why it is not a problem:**
The next stage (`scripts/coco/podvm/script-disk-mods-s390x.sh`) pins
`KERNEL_VERSION` explicitly and removes all kernels that do not match.
After that step only one kernel remains and `zipl` is re-run to reflect it.

---

### Observation 2 — RHSM credentials visible in one BLS entry

**What was seen:**
One of the three BLS entries (`6.12.0-211.53.1`) had the full RHSM
credentials in its `options` line:
```
options console=ttysclp0 inst.ks=file:/rhel10-s390x-dm-root.ks \
        inst.ks.org_id=<YOUR_ORG_ID> \
        inst.ks.activation_key=<YOUR_ACTIVATION_KEY>
```

**Why this happens:**
When `%post` installs a newer kernel via `dnf`, `kernel-install` runs
automatically and creates a new BLS entry. It copies the **current kernel
cmdline** (which includes the `inst.ks.*` parameters passed by
`build-s390x-base-image.sh`) into the new entry's `options` line.

**Why it is not a problem:**
`scripts/coco/podvm/script-disk-mods-s390x.sh` removes all kernels except
the pinned `KERNEL_VERSION` and regenerates BLS entries and the `zipl`
bootmap. The entry carrying the credentials is removed as part of that step.
The final image will **not** contain the credentials.

**However**, as an extra safety measure, it is worth also scrubbing the
cmdline from all BLS entries at the end of `%post` to ensure the base
image itself is clean before the CoCo step runs. This is tracked as a
future improvement.

---

### Observation 3 — Build duration

| Phase | Duration |
|---|---|
| Anaconda package installation (from DVD) | ~7 min |
| `%post` RHSM register + `dnf install` + deprovision | ~5 min |
| Total (start to `poweroff`) | **~12 min** |

The VM started at `10:11:50` UTC and shut down at `10:14:04` UTC per the
QEMU log — just over 2 minutes total. This is **much faster** than the
previous manual run (~50 min) because:
- No interactive prompts blocked progress
- No manual chroot/bind-mount/re-run steps were needed
- `--noautoconsole --wait -1` let the VM run at full speed

---

### Observation 4 — First automated build verification results

Every check passed on the freshly built image:

| Check | Result |
|---|---|
| `qemu-img check` | No errors |
| `vda1` PReP boot GUID | `9e1a2d38-…` ✅ |
| `vda2` root GUID | `08a7acea-624c-4a20-91e8-6e0fa67d23f9` (s390x DPS) ✅ |
| OS version | RHEL 10.2 ✅ |
| BLS boot entries | 3 entries (rescue + 2 kernels) ✅ |
| `zipl` bootmap | 133 KiB written ✅ |
| `WALinuxAgent` | `2.13.1.1-2.el10_1.1` installed via RHSM ✅ |
| `afterburn` | `5.10.0-1.el10` ✅ |
| `NetworkManager-cloud-setup` | `1.56.0-2.el10_2` ✅ |
| `kernel-modules-extra` | Both versions present (removed by next stage) ✅ |
| `python3-dnf-plugin-versionlock` | ✅ |
| `tpm2-tools`, `cryptsetup` | ✅ |
| SSH host keys | Cleared — `waagent -force -deprovision` ran ✅ |
| RHSM | Unregistered — no consumer cert ✅ |
| `waagent.service` | Enabled in `multi-user.target.wants` ✅ |
| New image size vs reference | Identical (7.1 GiB on disk) ✅ |

