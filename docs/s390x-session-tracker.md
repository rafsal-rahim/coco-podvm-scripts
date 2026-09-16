# s390x CoCo PodVM Build — Session Tracker

This file is updated continuously during the build session.
If the Bob conversation context is lost, start a new session and say:
**"Read docs/s390x-session-tracker.md and resume from where we left off."**

---

## Current Status

**Stage:** 🔧 **Bug #25 fix applied to script — ready for Stage 2+3 rebuild and boot test**
**Last updated:** Session 7 — fix applied to `script-disk-mods-s390x.sh`; rebuild required

### What happened in session 7

1. Reviewed session 6 archive — image intact, `veritysetup verify` exit 0 confirmed.
2. Ran boot tests with and without `systemd.volatile=overlay` on cmdline.
3. **`systemd-veritysetup@root.service` → success** ✅ — `/dev/mapper/root` assembled, `dev-mapper-root.device` reached `active`.
4. **`systemd-volatile-root.service` → failure** ❌ — exits 1, blocking `initrd-root-fs.target`.
5. Extracted initramfs (`gzip` compressed, 28 MiB → 66 MiB uncompressed), strace'd and inspected `systemd-volatile-root` binary.
6. **Root cause identified** — see Bug #25 below.

### What happened in session 6

1. Pre-flight checks passed: `/dev/kvm` present, disk clean (2 partitions, 7 GiB), NBD4 free.
2. Ran full Stage 2+3 pipeline (`create-verity-podvm-s390x.sh`) — **completed successfully**.
3. Final image: 3 partitions (`vda1` PReP 4 MiB, `vda2` root 7 GiB, `vda3` verity 501.8 MiB).
4. Both BLS entries correctly show `options root=/dev/mapper/root console=ttysclp0 systemd.volatile=overlay` — no `root=UUID=`, no `inst.ks.*` args. ✅
5. `veritysetup verify /dev/nbd4p2 /dev/nbd4p3 <roothash>` → **exit 0** ✅
6. **Roothash:** `64215ebe44c2237dfc8f151ef97886f3cc6efc07d0f477afb71fc19fdbc773f2`

---

## Repo Location

```
/home/linuxuser/suprit/new_build/coco-podvm-scripts/
```

---

## Images

| File | Location | Status |
|---|---|---|
| **Final image (live)** | `/home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2` | ✅ **dm-verity applied** — 3 partitions, `veritysetup verify` passed |
| **Archived copy** | `/home/linuxuser/suprit/new_build/archive/session6-podvm-verity-20260910/rhel10-s390x-podvm-verity.qcow2` | ✅ Safe copy — will not be overwritten by a rebuild |
| Reference (clean base) | `/home/linuxuser/suprit/new_build/output/rhel10-s390x-base-reference.qcow2` | ✅ Clean 2-partition base — never modified, copy from here to rebuild |
| disk.qcow2 | `/home/linuxuser/suprit/new_build/output/disk.qcow2` | ❌ Stale — do not use |
| Full pipeline log | `/tmp/coco-verity-build.log` → archived as `logs/coco-verity-build-session6.log` | ✅ Session 6 successful run |

**Roothash (session 6):** `64215ebe44c2237dfc8f151ef97886f3cc6efc07d0f477afb71fc19fdbc773f2`

### Archive location

```
/home/linuxuser/suprit/new_build/archive/session6-podvm-verity-20260910/
├── README.md                              ← roothash, checksums, boot instructions, rebuild guide
├── SHA256SUMS                             ← sha256 + md5 of the image
├── rhel10-s390x-podvm-verity.qcow2        ← final dm-verity protected CoCo PodVM image
└── logs/
    ├── coco-verity-build-session6.log     ← session 6 successful pipeline run (definitive)
    ├── stage1-base-image-build.log        ← Stage 1 virt-install base OS build
    ├── s390x-build-debug-history.log      ← full debug history across all pipeline attempts
    ├── guestfs-debug-copy-in-bug21.log    ← Bug #21 libguestfs verbose diagnosis
    └── s390x-console.log                  ← Anaconda serial console from early sessions
```

---

## Completed Steps

### Stage 1 — Base OS image ✅ DONE (Sep 9 07:44)

- Script: `helpers/build-s390x-base-image.sh`
- Kickstart: `helpers/rhel10-s390x-dm-root.ks`
- Output: `/home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2`
- Kernel: `6.12.0-211.53.1.el10_2.s390x`
- Root UUID: `25416c86-8148-4443-acf4-38b987471e25`

### Stage 2 — CoCo components ✅ DONE (session 6)

- `script-disk-mods-s390x.sh`: kernel pinned to `6.12.0-211.53.1`, dracut with `systemd-veritysetup` module + `parse-root.sh` patch, zipl updated ✅
- `podvm_maker-s390x.sh`: CoCo binaries (`kata-agent`, `attestation-agent`, `agent-protocol-forwarder`, etc.), services, SELinux labels, firewall port 15150/tcp ✅
- RHSM registered for dnf installs, unregistered cleanly — no entitlement in final image ✅

### Stage 3 — dm-verity ✅ DONE (session 6)

- 3 partitions: `vda1` PReP 4 MiB, `vda2` root 7 GiB, `vda3` verity hash 501.8 MiB ✅
- Both BLS entries: `options root=/dev/mapper/root console=ttysclp0 systemd.volatile=overlay` ✅
- No `root=UUID=`, no `inst.ks.*` args in any BLS entry ✅
- `veritysetup verify` exit 0 ✅
- Roothash: `64215ebe44c2237dfc8f151ef97886f3cc6efc07d0f477afb71fc19fdbc773f2`

### Stage 4 — Boot test 🔧 IN PROGRESS

- `systemd-veritysetup@root.service` → **success** ✅ (`/dev/mapper/root` assembled)
- `sysroot.mount` → **success** ✅ (ext4 ro mounted)
- `systemd-volatile-root.service` → **failure** ❌ (exits 1 — root cause diagnosed, fix pending)

---

## Active Bug

### Bug #25 — `systemd-volatile-root.service` exits 1: wrong volatile mode (`yes` vs `overlay`)

**Symptom:**
```
[FAILED] Failed to start systemd-volatile-root… Enforce Volatile Root File Systems.
[DEPEND] Dependency failed for initrd-root-fs.target
→ Emergency shell
```

**Root cause (confirmed by initramfs inspection + strace):**

The service unit in the initramfs has:
```
ExecStart=/usr/lib/systemd/systemd-volatile-root yes /sysroot
```

The argument `yes` maps to `VOLATILE_YES` mode inside the binary (`volatile_mode_from_string("yes")`).
`VOLATILE_YES` calls `make_volatile()` which:
1. Creates a tmpfs at `/run/systemd/volatile-sysroot`
2. Tries `mount(NULL, sysroot, NULL, MS_SLAVE|MS_REC, NULL)` — **fails `EINVAL`** (logged as "ignoring") because `/sysroot` is a **shared** mount in systemd's initrd namespace
3. Tries `mount(overlay, sysroot, NULL, MS_MOVE, NULL)` — **fails `EINVAL`** because the mount is still shared (MS_MOVE requires private or slave)
4. Exits 1

The argument should be `overlay` which maps to `VOLATILE_OVERLAY` / `make_overlay()`.
`make_overlay()` mounts a plain **overlayfs** (`lowerdir=/sysroot, upperdir=tmpfs/upper, workdir=tmpfs/work`) directly on `/sysroot` — **no `MS_MOVE` involved** — and works correctly on a shared mount.

**Key evidence from debug boot log (`/tmp/podvm-boot-debug2.log`):**
```
run-systemd-overlay\x2dsysroot.mount: Changed dead -> mounted   ← tmpfs created OK
run-systemd-overlay\x2dsysroot.mount: Deactivated successfully  ← cleaned up on failure
Child 496 (systemd-volatil) died (code=exited, status=1/FAILURE)
```

**Verified on host:** `mount -t overlay overlay -o lowerdir=<dm-verity-ext4-ro>,upperdir=...,workdir=...` succeeds → overlayfs over a read-only dm-verity lower dir works fine on this kernel.

**Fix — two parts:**

**Part A — image drop-in** (persists to real root, not needed for initrd boot but good hygiene):
```
/etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf
```
```ini
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot
```

**Part B — initramfs patch** (required — the service runs from the initramfs copy):
Add to `script-disk-mods-s390x.sh` (alongside the existing `parse-root.sh` patch, before the `dracut` call):
```bash
# Override volatile-root service to use 'overlay' mode (not 'yes'/VOLATILE_YES)
# VOLATILE_YES uses MS_MOVE which fails on shared mounts in the initrd.
# VOLATILE_OVERLAY uses overlayfs with a tmpfs upper — no MS_MOVE, works correctly.
mkdir -p /etc/systemd/system/systemd-volatile-root.service.d
cat > /etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot
EOF
```
dracut picks up `/etc/systemd/system/` drop-ins when building the initramfs — the override will be baked in.

**Status:** ✅ Fix applied to [`scripts/coco/podvm/script-disk-mods-s390x.sh`](scripts/coco/podvm/script-disk-mods-s390x.sh) — rebuild required to bake into image.

---

## All Fixed Bugs

| # | Error | Fix | Status |
|---|---|---|---|
| 1 | virt-install TTY warning | `--noautoconsole --wait -1` | ✅ |
| 2 | Anaconda kdump interactive prompt | `%addon com_redhat_kdump --disable` | ✅ |
| 3 | WALinuxAgent/kernel-uki-virt not on DVD | Move to `%post` dnf install | ✅ |
| 4 | kernel-uki-virt doesn't exist on s390x | Replace with plain `kernel*` packages | ✅ |
| 5 | `services` directive rejected unknown names | Only enable DVD-installed services | ✅ |
| 6 | No RHSM repos inside `%post` | Inject ORG_ID/ACTIVATION_KEY via kernel cmdline | ✅ |
| 7 | Anaconda Python crash → bash shell | Encode all steps in `%post --erroronfail` | ✅ |
| 8 | Wrong partition GUID on vda2 | `sfdisk --part-type` as first `%post` command | ✅ |
| 9 | `libguestfs-tools` wrong pkg name | `guestfs-tools libguestfs libguestfs-appliance` | ✅ |
| 10 | Hardcoded `KERNEL_VERSION` not in image | Auto-detect via `rpm -q kernel-core` | ✅ |
| 11 | `current_size` empty — `qemu-img info` after `qemu-nbd` held write lock | Moved before `qemu-nbd -c`; added empty-check | ✅ |
| 12 | `apply_dmverity()` generic type aliases mapped to `root-s390x` | `root-s390` / `root-s390-verity` / jq filter fixed | ✅ |
| 13 | `systemd-repart` v257 always outputs `roothash=TBD` for pre-existing partitions | Split: repart creates GPT entry; `veritysetup format` computes hash | ✅ |
| 14 | `zipl` chroot: `Could not get disk geometry` on NBD | Superseded by #16 | ✅ |
| 15 | `zipl --targetbase` missing required flags | Superseded by #16 | ✅ |
| 16 | `zipl` block-level I/O reads fail on NBD-backed ext4 | `patch_bls_and_run_zipl()`: patches BLS via host mount → disconnects NBD → runs zipl via virt-customize | ✅ |
| 17 | `lsblk PARTTYPE` always blank on this host's NBD driver; `fdisk`/`sfdisk`/`parted` fail with I/O errors | `find_root_part()` falls back to largest-partition heuristic; `create_verity_partition()` sorts by size desc | ✅ |
| 18 | `rm -rf /tmp/tmp.*` during cleanup removed bind-mounted `/dev/null`, `/dev/urandom`, `/dev/kvm` etc. from host | Recreated all missing nodes with `mknod` + correct major:minor numbers | ✅ |
| 19 | `virt-customize` ran under TCG emulation (`-accel tcg`) instead of KVM because `/dev/kvm` was missing | Killed slow TCG run; restored `/dev/kvm`; verified 11-second KVM test succeeds | ✅ |
| 20 | initramfs missing `systemd-veritysetup` module + `dracut-initqueue` deadlock → VM boots to udev then stalls | `--add systemd-veritysetup` on dracut call; `sed` patch of `parse-root.sh` adds veritysetup to initqueue bypass (restored after dracut) | ✅ |
| 21 | `virt-customize --copy-in` fails for large files: `libguestfs tar_in = -1, cancellation sent` (libguestfs-1.58.1 s390x) | Replace all `--copy-in` with `--upload` in `coco-components-s390x.sh` | ✅ |
| 22 | `fsck -p` exits 4 on dirty ext4 journal left by `virt-customize` | Changed to `fsck -y` in `verity-s390x.sh` | ✅ |
| 23 | `veritysetup verify` fails at position 0 — zipl ran after `veritysetup format` | Rewrote `verity-s390x.sh`: BLS patch + zipl first, `veritysetup format` last; roothash not in bootmap | ✅ |
| 24 | Main kernel BLS entry missing `root=` — Anaconda wrote it to `zipl.conf` only, not to the BLS `.conf`; kickstart-arg strip left no `root=` at all | Guard in `patch_bls_and_run_zipl()`: insert `root=/dev/mapper/root` after `options ` if not already present | ✅ |
| 25 | `systemd-volatile-root.service` exits 1 — service hardcodes `yes` (VOLATILE_YES / MS_MOVE path) which fails on shared initrd mounts; `overlay` (VOLATILE_OVERLAY / overlayfs) is the correct mode | Drop-in `/etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf` overrides `ExecStart` to use `overlay`; added before dracut rebuild so it is baked into initramfs | ✅ Script fixed — rebuild pending |

---

## Key Discoveries

### zipl writes to vda2 — veritysetup must be last (bug #23)
`zipl` writes `/boot/bootmap` to the root partition (vda2). `veritysetup format`
hashes ALL bytes of vda2. Any write to vda2 after `veritysetup format` invalidates
the hash at block 0 (bootmap lives near the start of the filesystem).

**The circular dependency:** the roothash = SHA256-hash-tree of all bytes of vda2,
including `/boot/bootmap`. Writing the roothash into the bootmap changes the
bytes being hashed → the hash changes → the value you wrote is wrong. No fixed
point exists. It is mathematically impossible to bake the roothash into the
bootmap at image-build time.

**Production solution:** supply the roothash at VM start time as a kernel cmdline
argument. `systemd-veritysetup-generator` reads `roothash=` from wherever it
appears on the cmdline. For CoCo PodVMs this is done via kata-agent config,
cloud-init, or Azure custom data — the infrastructure injects it when it starts
the VM. This is the same mechanism production CoCo uses today.

### Confirmed at session 5 by inspecting the bootmap
`strings /boot/bootmap` showed the real roothash (`878fb312...`) was correctly
present in the bootmap after the session-4 run. The image content was correct;
only the ordering (zipl after veritysetup) caused the hash to be stale.

### BLS entry `root=` can be absent on the main kernel entry (bug #24)
Anaconda on s390x writes `root=UUID=<uuid>` into `/etc/zipl.conf` (picked up
by zipl directly) but may **not** write it into the BLS `.conf` file for the
main kernel entry. The rescue entry always carries `root=UUID=` in its BLS
file; the main kernel entry may not. After the kickstart-arg strip in
`patch_bls_and_run_zipl()`, the options line for the main entry was left with
no `root=` at all, causing a kernel panic at boot. Fixed by an unconditional
guard that inserts `root=/dev/mapper/root` if it is absent.

### `/dev` node destruction (bugs #18–19)
The cleanup command `sudo rm -rf /tmp/tmp.*` while bind-mounts of `/dev/*` were
still active inside chroot directories deleted the underlying host device nodes
(`/dev/null`, `/dev/urandom`, `/dev/kvm`, etc.). Symptoms:
- `virt-customize` ran under TCG (no `/dev/kvm`) → 98% CPU, 12+ min with no progress
- `libguestfs error: guestfs_int_random_string: No such file or directory` (no `/dev/urandom`)
- `/etc/bashrc: line 80: /dev/null: Permission denied` in all shells

**Prevention:** Never `rm -rf` a directory that may contain bind-mounted `/dev` entries.
Always `umount -R <dir>` before removing.

### lsblk PARTTYPE blank on NBD (bug #17)
On this s390x host, the kernel's NBD driver never populates partition type GUIDs
in `/sys/class/block/*/uevent`. All GUID-based lookups silently return empty.
`fdisk`, `sfdisk`, `parted` all error with I/O on NBD devices.
**Workaround:** Size-based heuristics — root is always the largest partition.

### Ghost partition nodes (informational)
After disconnecting NBD, the kernel sometimes retains stale partition device nodes
(e.g. `nbd3p3`) from previous sessions. `lsblk` shows them but `guestfish` shows
the actual GPT contents. Always use `guestfish list-partitions` to verify real partition count.

### dracut veritysetup deadlock (bug #20)
`dracut-107` (RHEL 10.2) `parse-root.sh` only exempts `systemd-cryptsetup` from
the `dracut-initqueue` finished-hook wait on `/dev/mapper/root`. Because
`remote-veritysetup.target` is `After=remote-fs-pre.target` (which only starts
after `dracut-initqueue` exits), the boot deadlocks. Fixed in `script-disk-mods-s390x.sh`
with a targeted `sed` that adds the veritysetup bypass alongside the existing
cryptsetup one — file is restored immediately after `dracut`.

### systemd-volatile-root `yes` vs `overlay` mode (bug #25)

`systemd-volatile-root` supports two writable-root modes:

| Arg | Mode constant | Mechanism | MS_MOVE? |
|---|---|---|---|
| `yes` | `VOLATILE_YES` | `make_volatile()` — creates tmpfs `/run/systemd/volatile-sysroot`, binds `/usr` ro, then `MS_MOVE`s sysroot | **Yes** — fails on shared mounts |
| `overlay` | `VOLATILE_OVERLAY` | `make_overlay()` — mounts overlayfs over `/sysroot` with tmpfs upper/workdir | **No** — works on any mount |

In the initramfs, systemd's PID 1 namespace has `/sysroot` as a **shared** mount.
`MS_SLAVE` on it returns `EINVAL` (the log says "ignoring"), leaving the mount still
shared. The subsequent `MS_MOVE` then also returns `EINVAL`, and the service exits 1.

The service unit in RHEL 10 / systemd-257 initramfs hardcodes `yes`:
```
ExecStart=/usr/lib/systemd/systemd-volatile-root yes /sysroot
```

Dracut bakes in drop-ins from `/etc/systemd/system/` at `dracut` time. Adding a
drop-in **before the dracut call** in `script-disk-mods-s390x.sh` overrides the
`ExecStart` to `overlay` inside the initramfs without patching any upstream file.

**Confirmed on host:** overlayfs with a dm-verity ext4 read-only lowerdir mounts
successfully — the overlayfs path has no issue with a ro lower dir.

---

## Architecture Notes (quick reference)

| Topic | s390x value |
|---|---|
| Root partition GUID | `08a7acea-624c-4a20-91e8-6e0fa67d23f9` |
| Root partition type (systemd name) | **`root-s390`** (NOT `root-s390x`) |
| Verity hash partition GUID | `7ac63b47-b25c-463b-8df8-b4a94e6c90e1` |
| Verity partition type (systemd name) | **`root-s390-verity`** |
| PReP partition GUID | `9e1a2d38-c612-4316-aa26-8b49521e5a8b` |
| Disk device in guest | `vda` (virtio-blk via KVM) |
| Console | `ttysclp0` |
| Boot | `zipl` + PReP partition (no EFI/shim) |
| Roothash delivery | **Not in bootmap** — supplied at VM start via kernel cmdline arg `roothash=<hex>` |
| No UKI | `kernel-uki-virt` does not exist on s390x |
| KVM device | `/dev/kvm` major=10 minor=232 — must exist for fast builds |

---

## Next Steps (resume here)

### Step 0 — Pre-flight checks (for a rebuild)

```bash
# 1. Confirm /dev/kvm exists (required for fast virt-customize runs ~11s vs 30+ min TCG)
ls -la /dev/kvm || sudo mknod /dev/kvm c 10 232 && sudo chmod 660 /dev/kvm && sudo chgrp kvm /dev/kvm

# 2. Confirm no stale NBD connections
sudo qemu-nbd --disconnect /dev/nbd4 2>/dev/null || true
sudo lsof /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 2>/dev/null | head -5

# 3. Confirm base image is clean (2 partitions only)
sudo guestfish --ro -a /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 run : list-partitions
# Must show: /dev/sda1 and /dev/sda2 only
# If it shows /dev/sda3 the image is contaminated — restore from reference:
sudo cp /home/linuxuser/suprit/new_build/output/rhel10-s390x-base-reference.qcow2 \
        /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
sudo chown qemu:libvirt /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
```

### Step 1 — Run the full Stage 2 + 3 pipeline (if rebuilding)

```bash
cd /home/linuxuser/suprit/new_build/coco-podvm-scripts
export ACTIVATION_KEY=<YOUR_ACTIVATION_KEY>
export ORG_ID=<YOUR_ORG_ID>
export NBD_DEV=4
> /tmp/coco-verity-build.log
nohup sudo -E bash scripts/create-verity-podvm-s390x.sh \
    /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 \
    >> /tmp/coco-verity-build.log 2>&1 &
echo "PID: $!"
```

Monitor:
```bash
tail -f /tmp/coco-verity-build.log
```

Expected flow in log:
```
[virt-customize] RHSM register → script-disk-mods-s390x.sh (~30s) → podvm_maker-s390x.sh → RHSM unregister

Applying dm-verity (s390x) ...
Disk size         : 7516192768 bytes
Resizing disk ... Image resized.
Connecting disk via NBD ...
  lsblk PARTTYPE empty — falling back to largest-partition heuristic ...
Root partition: nbd4p2
fsck done.

Running systemd-repart to create verity hash partition ...
  "activity" : "create"   ← nbd4p3 (verity hash partition)
Data partition : /dev/nbd4p2
Hash partition : /dev/nbd4p3

Step 4 — patching BLS entries and running zipl ...
  Mounting root partition /dev/nbd4p2 ...
  Found 2 BLS entries — patching cmdline for dm-verity ...
    Patching: e3a76f77...-0-rescue.conf
    Result: options root=/dev/mapper/root console=ttysclp0 systemd.volatile=overlay
    Patching: e3a76f77...-6.12.0-211.53.1.el10_2.s390x.conf
    Result: options root=/dev/mapper/root console=ttysclp0 systemd.volatile=overlay
  BLS entries patched.
  Disconnecting NBD for virt-customize zipl run ...
  Running zipl via virt-customize to update bootmap ...
  [virt-customize ~11s] Running: zipl --verbose
  zipl updated via virt-customize.
  Reconnecting NBD for veritysetup ...

Step 5 — computing dm-verity roothash (last disk operation) ...
Running veritysetup format (final operation on vda2) ...
Root hash: <64-char hex>              ← KEY LINE — record this value

================================================================
dm-verity applied successfully.

Root hash: <64-char hex>

IMPORTANT: The roothash is NOT stored in the bootmap.
You MUST supply it at VM start time as a kernel cmdline argument:

  roothash=<64-char hex>
================================================================
```

If the run fails, check for stale locks and restore:
```bash
sudo fuser -k /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 2>/dev/null || true
sudo qemu-nbd --disconnect /dev/nbd4 2>/dev/null || true
sleep 2
sudo cp /home/linuxuser/suprit/new_build/output/rhel10-s390x-base-reference.qcow2 \
        /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
sudo chown qemu:libvirt /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
```

### Step 2 — Verify the image ✅ DONE (session 6)

All checks passed. For reference only:

```bash
# a) Check partition layout
sudo guestfish --ro -a /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 \
  run : list-partitions
# Expected: /dev/sda1 (PReP 4M), /dev/sda2 (root ~7G), /dev/sda3 (verity ~501M)

# b) Check BLS entries
sudo guestfish --ro -a /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 \
  run : mount /dev/sda2 / : glob cat /boot/loader/entries/*.conf
# Expected options line for BOTH entries: root=/dev/mapper/root ... systemd.volatile=overlay
# Must NOT contain: roothash=  root=UUID=  inst.ks=  inst.ks.org_id=
# Both entries MUST start with: options root=/dev/mapper/root

# c) Run veritysetup verify (replace <ROOTHASH> with the hash printed by the pipeline)
ROOTHASH=<paste roothash from pipeline output>
sudo qemu-nbd -c /dev/nbd4 -f qcow2 \
  /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
sleep 2
partprobe /dev/nbd4
sudo veritysetup verify /dev/nbd4p2 /dev/nbd4p3 "$ROOTHASH"
# Expected: exits 0 with no output (success)
sudo qemu-nbd --disconnect /dev/nbd4
```

### Step 3 — Apply Bug #25 fix and rebuild ← CURRENT STEP

**What to add to `scripts/coco/podvm/script-disk-mods-s390x.sh`** (inside the `if [ "$ARCH" = "s390x" ]` block, after the `parse-root.sh` patch write-out and before the `dracut` call):

```bash
# Bug #25 fix: override systemd-volatile-root.service to use 'overlay' mode.
# The stock service passes 'yes' (VOLATILE_YES) which uses MS_MOVE; that fails
# on shared initrd mounts.  'overlay' (VOLATILE_OVERLAY) uses overlayfs instead.
# Dracut bakes /etc/systemd/system/ drop-ins into the initramfs automatically.
mkdir -p /etc/systemd/system/systemd-volatile-root.service.d
cat > /etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot
EOF
```

**Pre-flight before rebuild:**
```bash
# Disconnect any stale NBD, restore clean base image
sudo virsh destroy podvm-verity-test 2>/dev/null || true
sudo qemu-nbd --disconnect /dev/nbd4 2>/dev/null || true
sudo cp /home/linuxuser/suprit/new_build/output/rhel10-s390x-base-reference.qcow2 \
        /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
sudo chown qemu:libvirt /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2
ls -la /dev/kvm || sudo mknod /dev/kvm c 10 232 && sudo chmod 660 /dev/kvm && sudo chgrp kvm /dev/kvm
```

**Run Stage 2 + 3 rebuild:**
```bash
cd /home/linuxuser/suprit/new_build/coco-podvm-scripts
export ACTIVATION_KEY=<YOUR_ACTIVATION_KEY>
export ORG_ID=<YOUR_ORG_ID>
export NBD_DEV=4
> /tmp/coco-verity-build.log
nohup sudo -E bash scripts/create-verity-podvm-s390x.sh \
    /home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2 \
    >> /tmp/coco-verity-build.log 2>&1 &
echo "PID: $!"
tail -f /tmp/coco-verity-build.log
```

**After rebuild — boot test:**
```bash
# Use the new roothash printed at end of pipeline
ROOTHASH=<new roothash from rebuild>
sudo virsh destroy podvm-verity-test 2>/dev/null || true
sudo virt-install \
  --name podvm-verity-test \
  --memory 2048 --vcpus 2 \
  --disk path=/home/linuxuser/suprit/new_build/output/rhel10-s390x-base.qcow2,format=qcow2,readonly=on \
  --boot kernel=/tmp/vmlinuz-6.12.0-211.53.1.el10_2.s390x,initrd=/tmp/initramfs-6.12.0-211.53.1.el10_2.s390x.img \
  --extra-args "root=/dev/mapper/root roothash=${ROOTHASH} systemd.verity_root_data=/dev/vda2 systemd.verity_root_hash=/dev/vda3 systemd.volatile=overlay console=ttysclp0 ro panic=30" \
  --serial file,path=/tmp/podvm-boot-session7.log \
  --graphics none --transient --noautoconsole
sleep 60
grep -E "login:|multi-user|kata-agent|emergency" /tmp/podvm-boot-session7.log | tail -20
```

**Expected success indicators:**
```
[  OK  ] Reached target multi-user.target
         Starting kata-agent.service ...
[  OK  ] Started kata-agent.service
rhel login:
```

**Previous (broken) boot command for reference:**
```bash
# DO NOT USE — volatile=overlay on cmdline with 'yes' in service = Bug #25
ROOTHASH=64215ebe44c2237dfc8f151ef97886f3cc6efc07d0f477afb71fc19fdbc773f2
```

---

## RHSM Credentials

```
ORG_ID=<YOUR_ORG_ID>
ACTIVATION_KEY=<YOUR_ACTIVATION_KEY>
```

---

## Key Files

| File | Purpose | Status |
|---|---|---|
| `helpers/rhel10-s390x-dm-root.ks` | Kickstart for base OS install | ✅ |
| `helpers/build-s390x-base-image.sh` | Automated virt-install wrapper (Stage 1) | ✅ |
| `scripts/create-verity-podvm-s390x.sh` | Top-level orchestrator (Stage 2 + 3) | ✅ |
| `scripts/coco/coco-components-s390x.sh` | CoCo component installer — uses `--upload` for tarballs | ✅ |
| `scripts/coco/podvm/script-disk-mods-s390x.sh` | Kernel pinning + dracut (`systemd-veritysetup` + `parse-root.sh` patch) + zipl | ✅ |
| `scripts/coco/podvm/podvm_maker-s390x.sh` | CoCo binaries, services, SELinux, firewall | ✅ |
| `scripts/verity/verity-s390x.sh` | dm-verity: repart → BLS patch → zipl → veritysetup (correct order, all 24 bugs fixed) | ✅ |
| `Dockerfile.s390x` | Build container (no ukify/sbsigntools) | ✅ |
| `docs/s390x-build-guide.md` | Full developer guide | ✅ |
| `helpers/rhel10-s390x-dm-root.md` | End-user build guide | ✅ |
