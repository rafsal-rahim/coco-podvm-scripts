# s390x CoCo PodVM — Build Readiness Report

**Host:** RHEL 10.2 · s390x · kernel `6.12.0-211.49.1.el10_2.s390x`

> **Overall: ✅ Ready to build — all checks passed, both action items resolved.**
> The system has everything needed to run the s390x image build.

---

## Platform

| Check | Status | Detail |
|---|---|---|
| Architecture | ✅ OK | s390x — native host, no cross-arch emulation needed |
| OS | ✅ OK | RHEL 10.2 — matches target image OS |
| Kernel | ✅ OK | `6.12.0-211.49.1.el10_2.s390x` |
| `/dev/kvm` | ✅ OK | Present and world-writable — user is in `kvm` group |
| libvirtd | ✅ OK | Active — `virt-install` can use it |
| RHSM subscription | ✅ OK | 2 repos enabled: BaseOS + AppStream for s390x |
| Network / quay.io | ✅ OK | HTTP 200 — can pull CoCo payload containers |
| Disk space | ✅ OK | 105 GB free on `/` — need ~25 GB for build + work dir |
| RAM | ✅ OK | 175 GB total, 132 GB available — well above the 8 GB `virt-customize` minimum |
| sudo / root access | ✅ OK | passwordless sudo confirmed |

---

## Core CLI Tools

| Tool | Status | Version / Package |
|---|---|---|
| `qemu-img` | ✅ OK | 10.1.0 — from `qemu-img` RPM |
| `qemu-nbd` | ✅ OK | 10.1.0 — binary ships inside the `qemu-img` RPM |
| `jq` | ✅ OK | 1.7.1 |
| `openssl` | ✅ OK | 3.5.5 |
| `podman` | ✅ OK | 5.8.2 |
| `virt-install` | ✅ OK | 5.1.0 — knows `rhel10.2` OS variant |
| `virt-customize` | ✅ OK | 1.54.0 — from `guestfs-tools` |
| `systemd-repart` | ✅ OK | 257 — from `systemd-udev` RPM |
| `zipl` | ✅ OK | 2.40.0 — from `s390utils-base` — s390x bootloader |
| `modprobe` / `nbd` | ✅ OK | kmod 31, `/dev/nbd0`–`nbd15` already present |
| `lsblk`, `blkid`, `partprobe`, `udevadm` | ✅ OK | util-linux 2.40.2 |
| `fsck.ext4` | ✅ OK | Present |
| `cryptsetup` | ✅ OK | Present |
| `sfdisk` | ✅ OK | Present — sets partition GUID in kickstart `%post` |
| `chroot`, `iconv` | ✅ OK | Present |

---

## libguestfs / virt-customize

| Check | Status | Detail |
|---|---|---|
| `libguestfs` RPM | ✅ OK | `1.58.1-9.el10_2.s390x` |
| `libguestfs-appliance` | ✅ OK | Installed — provides pre-built appliance for s390x |
| `libguestfs-xfs` | ✅ OK | Installed |
| `guestfs-tools` | ✅ OK | `1.54.0` — provides `virt-customize`, `virt-ls` |
| Appliance functional test | ✅ OK | `libguestfs-test-tool` completed: *TEST FINISHED OK* |
| `supermin.d` | ℹ️ NOTE | Directory is empty — appliance comes pre-built via `libguestfs-appliance`, not supermin. This is normal for RHEL 10. |

---

## Items Needing Action

### 1. RHEL 10 s390x ISO file — ✅ RESOLVED

No ISO found on disk and no optical drive present.

**Resolved:** `RHEL-10.2-s390x-dvd1.iso` (9.1 GB, MD5 `a174683a2ea4cb397f9b47fab3713d36`)
has been copied into the repo root and verified byte-for-byte against the source.
It is listed in `.gitignore` and will not be committed to git.

Use this path in `virt-install --location`:
```
RHEL-10.2-s390x-dvd1.iso
```

---

### 2. `Dockerfile.s390x` — `libguestfs-tools` package name — ✅ RESOLVED

On RHEL 10 the package is `guestfs-tools`, not `libguestfs-tools`.
The second `dnf install` line in `Dockerfile.s390x` references the old name
which does not exist on RHEL 10 and will cause the container build to fail.

**Fix — change in [`Dockerfile.s390x`](../Dockerfile.s390x):**

```diff
-RUN dnf install -y guestfs-tools libguestfs-tools && dnf clean all
+RUN dnf install -y guestfs-tools libguestfs libguestfs-appliance && dnf clean all
```

---

## Correctly Absent on s390x

These tools are present in the x86_64 build but are intentionally **not**
required on s390x:

| Tool / Package | Reason absent |
|---|---|
| `systemd-ukify` | UKI addon `.extra.d/verity.addon.efi` is an EFI-only mechanism — not used on s390x |
| `sbsigntools` | EFI Secure Boot signing — not applicable on s390x (IBM Secure Execution is a separate trust chain) |
| NVIDIA RPMs | NVIDIA does not produce s390x drivers |
| `BOOTX64.CSV` / shim | s390x boots via `zipl` + PReP partition, no EFI shim |
