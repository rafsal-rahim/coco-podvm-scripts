#!/bin/bash
set -e

# Apply dm-verity to an s390x disk image.
#
# Differences from the x86_64 verity.sh:
#
# 1. No EFI System Partition — s390x boots via zipl, not UEFI shim.
#    The verity roothash is NOT baked into /boot/bootmap at image-build time
#    (that would create a circular dependency: the roothash depends on the exact
#    bytes of vda2, which includes the bootmap; writing the roothash into the
#    bootmap before hashing makes it impossible to compute the correct hash).
#    Instead, the BLS entry and bootmap contain root=/dev/mapper/root with NO
#    roothash= argument. The roothash is printed at the end of this script and
#    must be supplied to the VM at start time as a kernel cmdline argument
#    (e.g. via Kata Containers kata-agent configuration or cloud-init userdata).
#
# 2. Root partition type GUID is the s390x Discoverable Partitions Spec value:
#    08a7acea-624c-4a20-91e8-6e0fa67d23f9
#
# 3. No UKI addon (.extra.d/verity.addon.efi) — that is an EFI-only concept.
#
# 4. No sbsigntools / Secure Boot signing — s390x uses a different chain of
#    trust (IBM Secure Execution), not UEFI Secure Boot shim signing.
#
# Pipeline order (important for correctness):
#   Step 1 — systemd-repart: create verity hash partition GPT entry (nbd?p3)
#   Step 2 — mount vda2, patch BLS entries:
#               * replace root=UUID=<raw> with root=/dev/mapper/root
#               * append systemd.volatile=overlay
#               * remove kickstart installer args (inst.ks, inst.ks.org_id, etc.)
#               * do NOT add roothash= (circular dependency)
#   Step 3 — disconnect NBD, run zipl via virt-customize
#             (bakes clean cmdline into /boot/bootmap on vda2)
#   Step 4 — reconnect NBD, run veritysetup format as the LAST write to vda2
#             (hashes the final state of vda2 including the updated bootmap)
#   Output — print roothash; caller/operator must supply it at VM start time

DISK=${DISK:-$1}

function local_help()
{
    echo "Usage: $0 <DISK>"
    echo "Usage: $0 help"
    echo ""
    echo "Apply dm-verity to an s390x disk image."
    echo ""
    echo "Options (define them as variables):"
    echo "DISK:                mandatory - path to the disk image"
    echo "DISK_FORMAT:         mandatory - qcow2, raw, or vpc"
    echo "RESIZE_DISK:         optional  - resize disk before applying verity. Default: yes"
    echo "NBD_DEV:             optional  - /dev/nbd\$NBD_DEV to use. Default: 0"
    echo "VERITY_FOLDER:       optional  - working directory. Default: temp dir in /tmp"
    echo "ROOT_PARTITION_UUID: optional  - GPT type UUID of the root partition."
    echo "                                 Default: 08a7acea-624c-4a20-91e8-6e0fa67d23f9 (s390x)"
    echo ""
    echo "Exiting"
}

if [[ "$DISK" == "help" ]]; then
    local_help
    exit 0
fi

if [ -z "${DISK}" ]; then
    echo "DISK is unset. Either export DISK= or pass it as the first argument."
    exit 1
fi

if [ -z "${DISK_FORMAT}" ]; then
    echo "DISK_FORMAT is unset. Set it with DISK_FORMAT={qcow2/raw/vpc}"
    exit 1
fi

here=$(pwd)
DISK=$(realpath "$DISK")

VERITY_FOLDER=${VERITY_FOLDER:-$(mktemp -d)}
VERITY_FOLDER=$(realpath "$VERITY_FOLDER")

# Space budget:
#   LUKS scratch partition  — 2500 MiB reserved
#   Verity hash partition   — 7 % of the current root size
LUKS_MINIMAL_SPACE_MB=2500

DISK_FORMAT=${DISK_FORMAT:-"raw"}
APPLY_VERITY=${APPLY_VERITY:-"true"}
# s390x root partition type GUID (Discoverable Partitions Spec)
ROOT_PARTITION_UUID=${ROOT_PARTITION_UUID:-"08a7acea-624c-4a20-91e8-6e0fa67d23f9"}
NBD_DEV=${NBD_DEV:-"0"}
NBD_DEVICE=/dev/nbd${NBD_DEV}
RESIZE_DISK=${RESIZE_DISK:-"yes"}

nbd_mounted=0
root_mounted=0

function print_params()
{
    echo ""
    echo "VERITY_FOLDER:       $VERITY_FOLDER"
    echo "DISK:                $DISK"
    echo "DISK_FORMAT:         $DISK_FORMAT"
    echo "RESIZE_DISK:         $RESIZE_DISK"
    echo "NBD_DEVICE:          $NBD_DEVICE"
    echo "ROOT_PARTITION_UUID: $ROOT_PARTITION_UUID"
    echo ""
}

function handle_cleanup()
{
    if [[ $root_mounted -eq 1 ]]; then
        umount "$VERITY_FOLDER/mnt" 2>/dev/null || true
    fi
    if [[ $nbd_mounted -eq 1 ]]; then
        qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
    fi
    cd "$here"
}

trap handle_cleanup SIGINT
trap handle_cleanup EXIT

# ── helpers ────────────────────────────────────────────────────────────────

function resize_disk()
{
    local disk_path=$1
    local MB=$((1024 * 1024))
    local luks_space=$(( LUKS_MINIMAL_SPACE_MB * MB ))
    local new_size=$(( current_size + luks_space + verity_max_space ))
    local rounded=$(( (new_size + MB - 1) / MB * MB ))
    echo "Current disk size : $current_size bytes"
    echo "New disk size     : $rounded bytes"
    qemu-img resize "$disk_path" -f "$DISK_FORMAT" "${rounded}"
}

# Find the root partition.
# Exports ROOT_PN (e.g. "nbd3p2").
#
# Strategy:
#   1. Try lsblk PARTTYPE — works on most kernels.
#   2. On this s390x host the NBD driver never populates PARTTYPE (all blank).
#      fdisk/sfdisk/parted also fail with I/O errors against NBD devices.
#      Fall back to positional lookup: the root partition is always the largest
#      partition on the disk (PReP=4 MiB, root=7 GiB, any verity hash smaller).
function find_root_part()
{
    echo "Searching for root partition (type UUID: $ROOT_PARTITION_UUID) ..."

    # Primary: lsblk PARTTYPE (works on most kernels)
    ROOT_PN=$(lsblk -o NAME,PARTTYPE -r "$NBD_DEVICE" \
        | grep -i "$ROOT_PARTITION_UUID" | awk '{print $1}')

    # Fallback: largest partition by size (root is always the largest)
    if [[ -z "$ROOT_PN" ]]; then
        echo "  lsblk PARTTYPE empty — falling back to largest-partition heuristic ..."
        ROOT_PN=$(lsblk -o NAME,SIZE -r "$NBD_DEVICE" \
            | tail -n +2 \
            | grep -v "^${NBD_DEVICE#/dev/} " \
            | sort -k2 -h \
            | tail -1 \
            | awk '{print $1}')
    fi

    if [[ -z "$ROOT_PN" ]]; then
        echo "Error: could not find root partition on $NBD_DEVICE" >&2
        exit 1
    fi
    local count
    count=$(echo "$ROOT_PN" | wc -l)
    if [[ "$count" -ne 1 ]]; then
        echo "Error: expected exactly one root partition, found $count: $ROOT_PN"
        exit 1
    fi
    echo "Root partition: $ROOT_PN"
}

function call_fsck()
{
    local fs_type
    fs_type=$(blkid -o value -s TYPE "/dev/$ROOT_PN")
    # Use -y (yes to all repairs) rather than -p (preen).
    # After virt-customize writes to the filesystem and exits, the ext4 journal
    # may be in an unclean state (dirty bit set). fsck -p refuses to repair a
    # dirty journal and exits 4 with "is mounted". fsck -y recovers it safely.
    fsck."$fs_type" -y "/dev/$ROOT_PN" || {
        local rc=$?
        # fsck exit 1 = corrected errors (ok to continue)
        # fsck exit 2 = reboot needed (rare, continue anyway for image builds)
        # fsck exit 4+ = uncorrected errors (abort)
        if [[ $rc -ge 4 ]]; then
            echo "Error: fsck exited $rc — uncorrectable errors on /dev/$ROOT_PN" >&2
            exit 1
        fi
        echo "fsck: errors corrected (exit $rc), continuing."
    }
    echo "fsck done."
}

# Create the verity hash partition GPT entry.
#
# Uses systemd-repart to allocate the partition table entry for the verity hash
# partition (type root-s390-verity). Does NOT compute the hash — that is done
# later by compute_roothash() as the very last operation.
#
# Exports DATA_DEV and HASH_DEV (block device paths, e.g. /dev/nbd4p2, /dev/nbd4p3).
function create_verity_partition()
{
    local WORKDIR="$VERITY_FOLDER/conf"
    mkdir -p "$WORKDIR"

    cat > "$WORKDIR/verity.conf" <<EOF
[Partition]
Type=root-s390-verity
Verity=hash
VerityMatchKey=root
PaddingWeight=1
SizeMinBytes=64M
SizeMaxBytes=${verity_max_space}
EOF

    cat > "$WORKDIR/root.conf" <<EOF
[Partition]
Type=root-s390
Verity=data
VerityMatchKey=root
SizeMaxBytes=${current_size}
EOF

    echo "Running systemd-repart to create verity hash partition ..."
    systemd-repart "$NBD_DEVICE" \
        --dry-run=no \
        --definitions="$WORKDIR" \
        --no-pager \
        --json=pretty 2>&1 | grep -E '^\[|"type"|"node"|"activity"' || true

    rm -rf "$WORKDIR"

    partprobe "$NBD_DEVICE"
    udevadm settle
    sleep 2

    # Identify data and hash partitions by size (lsblk PARTTYPE is blank on NBD).
    local _base="${NBD_DEVICE#/dev/}"
    local _sorted
    _sorted=$(lsblk -o NAME,SIZE -r "$NBD_DEVICE" \
        | tail -n +2 \
        | grep -v "^${_base} " \
        | sort -k2 -rh)

    local _data_pn _hash_pn
    _data_pn=$(echo "$_sorted" | awk 'NR==1{print $1}')
    _hash_pn=$(echo "$_sorted" | awk 'NR==2{print $1}')

    if [[ -z "$_data_pn" ]]; then
        echo "Error: could not find root data partition on $NBD_DEVICE" >&2
        exit 1
    fi
    if [[ -z "$_hash_pn" ]]; then
        echo "Error: could not find verity hash partition on $NBD_DEVICE" >&2
        echo "systemd-repart may not have created it — check output above." >&2
        exit 1
    fi

    DATA_DEV="/dev/${_data_pn}"
    HASH_DEV="/dev/${_hash_pn}"
    export DATA_DEV HASH_DEV

    echo "Data partition : $DATA_DEV"
    echo "Hash partition : $HASH_DEV"
}

# Patch BLS boot entries and re-run zipl.
#
# What this function does:
#   1. Mounts vda2, patches every BLS .conf file:
#        - replace root=UUID=<raw-uuid> with root=/dev/mapper/root
#        - append systemd.volatile=overlay to the options line
#        - strip installer-time kickstart args (inst.ks.*, inst.ks=)
#        - does NOT add roothash= (roothash is supplied at VM start time)
#   2. Unmounts vda2.
#   3. Disconnects NBD (virt-customize needs exclusive access to the disk).
#   4. Runs zipl inside the guest via virt-customize — bakes the clean cmdline
#      (with root=/dev/mapper/root but without roothash=) into /boot/bootmap.
#   5. Reconnects NBD so compute_roothash() can hash the final vda2.
#
# Why NOT include roothash= in the bootmap:
#   The roothash is the cryptographic hash of ALL bytes of vda2, including
#   /boot/bootmap. Writing the roothash into the bootmap before hashing makes
#   this a circular dependency (the hash would need to include itself).
#   The correct production approach for CoCo PodVMs is to supply the roothash
#   at VM start time as a kernel cmdline argument (e.g. via kata-agent config
#   or cloud-init). systemd-veritysetup-generator reads roothash= from the
#   kernel cmdline regardless of how it was delivered.
#
# zipl cannot be run via chroot against an NBD-backed filesystem because:
#   - NBD block-level I/O errors occur when zipl tries to read kernel/initrd
#     files for the bootmap (even when the files are readable at the VFS level)
#   - This is a known issue with zipl + NBD on this s390x host (Bug #14/#15)
# Solution: patch BLS entries while the disk is NBD-mounted (text file writes
# are safe), then disconnect NBD and run zipl inside the guest via virt-customize
# — exactly the same mechanism used by script-disk-mods-s390x.sh in Stage 2.
function patch_bls_and_run_zipl()
{
    echo "Mounting root partition /dev/$ROOT_PN ..."
    mount "/dev/$ROOT_PN" "$VERITY_FOLDER/mnt"
    root_mounted=1

    local entries_dir="$VERITY_FOLDER/mnt/boot/loader/entries"

    if [[ ! -d "$entries_dir" ]]; then
        echo "Error: BLS entries directory not found at $entries_dir"
        echo "Make sure the image has a kernel installed and kernel-install has run."
        exit 1
    fi

    local entry_count
    entry_count=$(find "$entries_dir" -maxdepth 1 -name "*.conf" | wc -l)
    if [[ "$entry_count" -eq 0 ]]; then
        echo "Error: No BLS entry files (*.conf) found in $entries_dir"
        exit 1
    fi

    echo "Found $entry_count BLS entries — patching cmdline for dm-verity ..."
    for entry in "$entries_dir"/*.conf; do
        echo "  Patching: $(basename "$entry")"

        # 1. Replace root=UUID=<uuid> with root=/dev/mapper/root.
        #    (verity assembles the root device at /dev/mapper/root)
        sed -i "s|root=UUID=[^ ]*|root=/dev/mapper/root|g" "$entry"

        # 2. Strip kickstart installer arguments that were baked in during
        #    Anaconda's OS install and must not appear in the final PodVM cmdline.
        #    These args make no sense (and may leak credentials) in a running VM.
        sed -i 's| *inst\.ks=[^ ]*||g' "$entry"
        sed -i 's| *inst\.ks\.[^ ]*=[^ ]*||g' "$entry"

        # 3. Ensure root=/dev/mapper/root is present on the options line.
        #    Some BLS entries (e.g. the main kernel entry generated by kernel-install)
        #    may not carry a root= arg at all — Anaconda can write it only to
        #    zipl.conf rather than the BLS file. Insert it right after 'options '
        #    so it is always first and always present.
        if ! grep -q "root=/dev/mapper/root" "$entry"; then
            sed -i "s|^options |options root=/dev/mapper/root |" "$entry"
        fi

        # 4. Append systemd.volatile=overlay if not already present.
        #    This makes the root filesystem copy-on-write via tmpfs overlay so
        #    the dm-verity protected root can never be written to.
        if ! grep -q "systemd\.volatile=overlay" "$entry"; then
            sed -i "/^options / s/$/ systemd.volatile=overlay/" "$entry"
        fi

        # NOTE: roothash= is intentionally NOT added here.
        # See function header for the explanation.

        echo "  Result: $(grep '^options' "$entry")"
    done

    root_mounted=0
    umount "$VERITY_FOLDER/mnt"
    echo "BLS entries patched."

    # Disconnect NBD before handing the disk to virt-customize.
    echo "Disconnecting NBD for virt-customize zipl run ..."
    qemu-nbd --disconnect "$NBD_DEVICE"
    nbd_mounted=0
    udevadm settle
    sleep 2

    # Run zipl inside the guest via virt-customize.
    # This avoids all NBD block-level I/O issues — zipl runs against /dev/vda
    # (the real virtio disk) inside a KVM guest, exactly as in Stage 2.
    # After this step, /boot/bootmap contains the clean cmdline with
    # root=/dev/mapper/root (without roothash=).
    echo "Running zipl via virt-customize to update bootmap ..."
    virt-customize \
        -a "$DISK" \
        --run-command 'zipl --verbose' \
        --selinux-relabel
    local vc_rc=$?
    if [[ $vc_rc -ne 0 ]]; then
        echo "Error: virt-customize zipl run failed (exit $vc_rc)" >&2
        exit 1
    fi
    echo "zipl updated via virt-customize."

    # Reconnect NBD for the veritysetup format step.
    echo "Reconnecting NBD for veritysetup ..."
    # Wait for virt-customize write lock to release (up to 30s)
    for _i in $(seq 1 15); do
        if qemu-nbd -c "$NBD_DEVICE" -f "$DISK_FORMAT" "$DISK" 2>/dev/null; then
            nbd_mounted=1
            break
        fi
        echo "  Waiting for write lock to release... ($_i)"
        sleep 2
    done
    if [[ $nbd_mounted -eq 0 ]]; then
        echo "Error: could not reopen disk after zipl — write lock not released" >&2
        exit 1
    fi
    udevadm settle
    sleep 2

    # Re-identify partition devices after reconnect (device names are stable
    # since no new partitions are created between here and compute_roothash).
    partprobe "$NBD_DEVICE" 2>/dev/null || true
    udevadm settle
    sleep 1
}

# Compute the dm-verity hash tree.
#
# MUST be called AFTER all writes to the data partition are complete
# (BLS entries patched, zipl bootmap written) so the hash covers the
# final filesystem state. This is the last operation that touches the disk.
#
# Exports RH (hex roothash string).
function compute_roothash()
{
    echo "Running veritysetup format (final operation on vda2) ..."
    RH=$(veritysetup format "$DATA_DEV" "$HASH_DEV" \
        | grep "^Root hash:" \
        | awk '{print $3}')

    if [[ -z "$RH" ]]; then
        echo "Error: veritysetup format did not return a root hash." >&2
        exit 1
    fi

    echo "Root hash: $RH"
    export RH
}

# ── main ───────────────────────────────────────────────────────────────────

print_params

# Capture disk size BEFORE connecting via NBD.
# qemu-img info requires exclusive (write) access — it cannot open the disk
# once qemu-nbd holds the write lock. current_size and verity_max_space are
# exported here and reused by both resize_disk() and apply_dmverity().
echo "Reading disk size from: $DISK"
current_size=$(qemu-img info -f "$DISK_FORMAT" --output json "$DISK" | jq '."virtual-size"')
if [[ -z "$current_size" || "$current_size" == "null" ]]; then
    echo "Error: could not read disk size — is the image locked by another process?" >&2
    echo "       Run: sudo lsof $DISK" >&2
    exit 1
fi
verity_max_space=$(( current_size * 7 / 100 ))
export current_size
export verity_max_space
echo "Disk size         : $current_size bytes"
echo "Verity max space  : $verity_max_space bytes"

if [[ "$RESIZE_DISK" == "yes" ]]; then
    echo ""
    echo "Resizing disk ..."
    resize_disk "$DISK"
fi

cd "$VERITY_FOLDER"
mkdir -p mnt

echo ""
echo "Connecting disk via NBD ..."
modprobe nbd
qemu-nbd -c "$NBD_DEVICE" -f "$DISK_FORMAT" "$DISK"
nbd_mounted=1
udevadm settle
sleep 2

# Step 1 — locate the root partition
echo ""
find_root_part

# Step 2 — filesystem check
echo ""
call_fsck

if [[ "$APPLY_VERITY" == "true" ]]; then
    # Step 3 — allocate the verity hash partition in the GPT.
    # This only writes the GPT partition table entry; the hash data
    # is written later by veritysetup format (Step 5).
    echo ""
    create_verity_partition

    # Step 4 — patch BLS entries and re-run zipl.
    # After this step:
    #   - All BLS .conf files have root=/dev/mapper/root + systemd.volatile=overlay
    #   - /boot/bootmap has the updated cmdline (WITHOUT roothash=)
    #   - vda2 is in its final, stable state ready for hashing
    echo ""
    echo "Step 4 — patching BLS entries and running zipl ..."
    patch_bls_and_run_zipl

    # Step 5 — hash the finalised data partition.
    # veritysetup format writes ONLY to HASH_DEV (nbd?p3).
    # It reads DATA_DEV (nbd?p2 = vda2) but does not write to it.
    # This is therefore the last operation touching any disk data.
    echo ""
    echo "Step 5 — computing dm-verity roothash (last disk operation) ..."
    compute_roothash

    echo ""
    echo "================================================================"
    echo "dm-verity applied successfully."
    echo ""
    echo "Root hash: $RH"
    echo ""
    echo "IMPORTANT: The roothash is NOT stored in the bootmap."
    echo "You MUST supply it at VM start time as a kernel cmdline argument:"
    echo ""
    echo "  roothash=${RH}"
    echo ""
    echo "For Kata Containers / CoCo PodVM deployment:"
    echo "  Set roothash= in the kata-agent configuration or pass it via"
    echo "  cloud-init userdata / Azure custom data at VM creation time."
    echo "================================================================"

    # Disconnect cleanly; trap will not double-disconnect.
    qemu-nbd --disconnect "$NBD_DEVICE"
    nbd_mounted=0
fi

# Cleanup
echo ""
echo "Disconnecting NBD device ..."
qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
nbd_mounted=0
rm -rf mnt
cd "$here"
