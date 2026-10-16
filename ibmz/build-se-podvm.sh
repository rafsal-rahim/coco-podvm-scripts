#!/usr/bin/env bash
#
# build-se-podvm.sh — Package a dm-verity protected s390x PodVM into an IBM Secure Execution (.protvirt) image
#                      or copy it onto the ext4 /boot-se partition (vda1) to produce a self-contained all-in-one QCOW2 image.
#
# This script supports two operational modes:
#
#   Mode 1 (Standalone .protvirt):
#     - Extracts kernel & initramfs from the qcow2 root partition (vda2).
#     - Builds an encrypted, sealed .protvirt binary using genprotimg.
#     - Used for direct-kernel boot (<kernel>path.protvirt</kernel>) in Libvirt/CAA.
#
#   Mode 2 (All-in-One QCOW2 with --write-to-disk):
#     - Generates the .protvirt image.
#     - Copies the .protvirt as a regular file onto the ext4 /boot-se partition (vda1)
#       created by the kickstart (Bug 19: plain partition, no PReP 4-10 MiB cap).
#     - The .protvirt is a sealed SE image, not a zipl-signed kernel, so it boots via
#       direct-kernel boot: libvirt <kernel> points at /boot-se/<file>.protvirt with
#       roothash= on the kernel cmdline, without modifying vda2 (root) or vda3 (hash),
#       preserving dm-verity integrity.
#
set -euo pipefail

function usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <INPUT_QCOW2_IMAGE>

Arguments:
  INPUT_QCOW2_IMAGE               Path to the dm-verity protected qcow2 image (e.g. rhel10-s390x-base.qcow2)

Options (via environment variables or flags):
  -k, --host-key <PATH>           Path to IBM Z Host Key Document (HKD) certificate (.crt/.pem) OR
                                  a directory containing .crt/.pem host keys (e.g. /etc/se-keys/).
                                  Multiple files/directories can be passed comma-separated or via multiple -k flags.
                                  (Env: HKD_PATH)
  -c, --cert, --cert-repo <PATH>  Path to IBM Z HKD CA certificate (.crt/.pem) file OR
                                  directory containing IBM Z signing CA certificates / CRLs.
                                  Multiple files/directories can be passed.
                                  (Env: CERT_REPO_PATH or CERT_PATH)
      --no-verify                 Disable host key certificate verification.
  -r, --roothash <HASH>           dm-verity roothash. Defaults to reading <INPUT_IMAGE>.roothash
                                  (Env: ROOTHASH)
  -o, --output <PATH>             Output path for the generated .protvirt image.
                                  Defaults to <INPUT_IMAGE_DIR>/<IMAGE_BASENAME>.protvirt
                                  (Env: OUTPUT_PROTVIRT)
  -w, --write-to-disk             Self-Contained "All-in-One" QCOW2 mode:
                                  Copies the generated .protvirt payload as a regular file onto
                                  the ext4 /boot-se partition (vda1) of the qcow2 image without
                                  touching vda2, keeping dm-verity intact.
      --disk-out <PATH>           Output path for the modified qcow2 when using --write-to-disk.
                                  If omitted, writes directly to <INPUT_QCOW2_IMAGE>.
  -h, --help                      Show this help message.

Examples:
  # Mode 1: Generate standalone .protvirt binary
  $0 -k /etc/se-keys/ibm-z-hostkey.crt \\
     -c /etc/se-keys/crls/ \\
     /home/linuxuser/output/rhel10-s390x-base.qcow2

  # Mode 2: Generate All-in-One self-contained QCOW2 image
  $0 -k /etc/se-keys/ibm-z-hostkey.crt \\
     -c /etc/se-keys/crls/ \\
     --write-to-disk \\
     --disk-out /home/linuxuser/output/rhel10-s390x-se-allinone.qcow2 \\
     /home/linuxuser/output/rhel10-s390x-base.qcow2
EOF
}

HOST_KEYS=()
CERTS=()
NO_VERIFY=0
CLI_ROOTHASH="${ROOTHASH:-}"
OUTPUT_PATH="${OUTPUT_PROTVIRT:-}"
WRITE_TO_DISK=0
DISK_OUT=""
INPUT_IMAGE=""

if [[ -n "${CERT_REPO_PATH:-}" ]]; then
    CERTS+=("$CERT_REPO_PATH")
fi
if [[ -n "${CERT_PATH:-}" ]]; then
    CERTS+=("$CERT_PATH")
fi

# Parse command-line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--host-key|--host-key-document)
            HOST_KEYS+=("$2")
            shift 2
            ;;
        -c|--cert|--cert-repo)
            CERTS+=("$2")
            shift 2
            ;;
        --no-verify)
            NO_VERIFY=1
            shift
            ;;
        -r|--roothash)
            CLI_ROOTHASH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -w|--write-to-disk)
            WRITE_TO_DISK=1
            shift
            ;;
        --disk-out)
            DISK_OUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$INPUT_IMAGE" ]]; then
                INPUT_IMAGE="$1"
                shift
            else
                echo "ERROR: Unknown argument: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$INPUT_IMAGE" ]]; then
    echo "ERROR: Missing input qcow2 image." >&2
    usage
    exit 1
fi

if [[ ! -f "$INPUT_IMAGE" ]]; then
    echo "ERROR: Input image not found: $INPUT_IMAGE" >&2
    exit 1
fi

# Fallback to HKD_PATH env if no -k was supplied
if [[ ${#HOST_KEYS[@]} -eq 0 && -n "${HKD_PATH:-}" ]]; then
    IFS=',' read -ra ADDR <<< "$HKD_PATH"
    for k in "${ADDR[@]}"; do
        HOST_KEYS+=("$k")
    done
fi

# Expand any directories supplied in HOST_KEYS into individual key files (.crt, .pem, .cer)
RESOLVED_HOST_KEYS=()
for key_entry in "${HOST_KEYS[@]}"; do
    if [[ -d "$key_entry" ]]; then
        echo "Scanning directory for host keys: $key_entry"
        # Glob for certificates without process substitution (works even if /dev/fd or /dev/null is missing)
        shopt -s nullglob
        for cert_file in "$key_entry"/*.crt "$key_entry"/*.pem "$key_entry"/*.cer; do
            if [[ -f "$cert_file" ]]; then
                RESOLVED_HOST_KEYS+=("$cert_file")
            fi
        done
        shopt -u nullglob
    elif [[ -f "$key_entry" ]]; then
        RESOLVED_HOST_KEYS+=("$key_entry")
    else
        echo "ERROR: Host key path not found (not a file or directory): $key_entry" >&2
        exit 1
    fi
done

if [[ ${#RESOLVED_HOST_KEYS[@]} -eq 0 ]]; then
    echo "ERROR: No valid IBM Z Host Key Documents (.crt, .pem, .cer) found in provided path(s)." >&2
    usage
    exit 1
fi

# Expand any directories supplied in CERTS into individual CA key files (.crt, .pem, .crl)
RESOLVED_CERTS=()
for cert_entry in "${CERTS[@]}"; do
    if [[ -d "$cert_entry" ]]; then
        echo "Scanning directory for CA certificates: $cert_entry"
        shopt -s nullglob
        for c in "$cert_entry"/*.crt "$cert_entry"/*.pem "$cert_entry"/*.cer "$cert_entry"/*.crl; do
            if [[ -f "$c" ]]; then
                RESOLVED_CERTS+=("$c")
            fi
        done
        shopt -u nullglob
    elif [[ -f "$cert_entry" ]]; then
        RESOLVED_CERTS+=("$cert_entry")
    else
        echo "ERROR: Cert path not found (not a file or directory): $cert_entry" >&2
        exit 1
    fi
done

if [[ $NO_VERIFY -eq 0 && ${#RESOLVED_CERTS[@]} -eq 0 ]]; then
    echo "WARNING: No CA certs specified. If host key validation fails, pass --cert <DIR_OR_FILE> or --no-verify."
fi

# Verify required tools
if ! command -v genprotimg &>/dev/null; then
    echo "ERROR: 'genprotimg' command not found. Please install 's390-tools' or 'genprotimg' package." >&2
    exit 1
fi

if ! command -v guestfish &>/dev/null; then
    echo "ERROR: 'guestfish' command not found. Please install 'libguestfs-tools' / 'guestfs-tools'." >&2
    exit 1
fi

# Determine roothash
ROOTHASH=""
if [[ -n "$CLI_ROOTHASH" ]]; then
    ROOTHASH="$CLI_ROOTHASH"
elif [[ -f "${INPUT_IMAGE}.roothash" ]]; then
    ROOTHASH="$(tr -d '[:space:]' < "${INPUT_IMAGE}.roothash")"
else
    echo "ERROR: Roothash not provided and sidecar '${INPUT_IMAGE}.roothash' was not found." >&2
    echo "Please provide the roothash via -r / --roothash or generate the sidecar first." >&2
    exit 1
fi

if [[ ! "$ROOTHASH" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: Invalid roothash format ('$ROOTHASH'). Expected a 64-character hex string." >&2
    exit 1
fi

IMG_DIR="$(dirname "$INPUT_IMAGE")"
IMG_BASE="$(basename "$INPUT_IMAGE" .qcow2)"

# Set default output path if not specified
if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="${IMG_DIR}/${IMG_BASE}.protvirt"
fi

WORKDIR=$(mktemp -d /tmp/build-se-podvm.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "================================================================"
echo " Building IBM Secure Execution PodVM Image (.protvirt)"
echo "================================================================"
echo "Input Image       : $INPUT_IMAGE"
echo "Root Hash         : $ROOTHASH"
echo "Output ProtVirt   : $OUTPUT_PATH"
echo "Host Keys (${#RESOLVED_HOST_KEYS[@]} found):"
for k in "${RESOLVED_HOST_KEYS[@]}"; do
    echo "  - $k"
done
if [[ $NO_VERIFY -eq 1 ]]; then
    echo "Verification      : Disabled (--no-verify)"
elif [[ ${#RESOLVED_CERTS[@]} -gt 0 ]]; then
    echo "CA Certs/CRLs (${#RESOLVED_CERTS[@]} found):"
    for c in "${RESOLVED_CERTS[@]}"; do
        echo "  - $c"
    done
fi
if [[ $WRITE_TO_DISK -eq 1 ]]; then
    echo "Mode              : All-in-One QCOW2 (--write-to-disk)"
    echo "Target QCOW2      : ${DISK_OUT:-$INPUT_IMAGE}"
else
    echo "Mode              : Standalone .protvirt"
fi
echo "Working Temp Dir  : $WORKDIR"
echo "----------------------------------------------------------------"

echo "[1/4] Inspecting root partition in qcow2 to find kernel and initramfs..."
# Find root partition (usually /dev/sda2)
ROOT_PART=$(guestfish --ro -a "$INPUT_IMAGE" run : list-partitions | grep -E 'sda2|vda2' | head -1 || true)
if [[ -z "$ROOT_PART" ]]; then
    # Default to second partition if standard naming isn't matched
    ROOT_PART=$(guestfish --ro -a "$INPUT_IMAGE" run : list-partitions | sed -n '2p')
fi

if [[ -z "$ROOT_PART" ]]; then
    echo "ERROR: Unable to locate root partition in $INPUT_IMAGE" >&2
    exit 1
fi
echo "Using root partition: $ROOT_PART"

# List /boot files to find the latest vmlinuz and initramfs
BOOT_FILES=$(guestfish --ro -a "$INPUT_IMAGE" -m "$ROOT_PART" ls /boot)

VMLINUZ_FILE=$(echo "$BOOT_FILES" | grep '^vmlinuz-' | sort -V | tail -1 || true)
INITRAMFS_FILE=$(echo "$BOOT_FILES" | grep '^initramfs-.*\.img$' | grep -v 'kdump' | sort -V | tail -1 || true)

if [[ -z "$VMLINUZ_FILE" || -z "$INITRAMFS_FILE" ]]; then
    echo "ERROR: Could not find vmlinuz or initramfs in /boot of $ROOT_PART." >&2
    exit 1
fi

echo "Selected Kernel   : /boot/$VMLINUZ_FILE"
echo "Selected Initramfs: /boot/$INITRAMFS_FILE"

echo "[2/4] Extracting kernel and initramfs from image..."
guestfish --ro -a "$INPUT_IMAGE" -m "$ROOT_PART" \
    download "/boot/$VMLINUZ_FILE" "$WORKDIR/vmlinuz" \
    : download "/boot/$INITRAMFS_FILE" "$WORKDIR/initramfs"

if [[ ! -s "$WORKDIR/vmlinuz" || ! -s "$WORKDIR/initramfs" ]]; then
    echo "ERROR: Failed to extract non-empty kernel or initramfs." >&2
    exit 1
fi

echo "[3/4] Assembling sealed kernel command line..."
CMDLINE="root=/dev/mapper/root roothash=${ROOTHASH} systemd.verity_root_data=/dev/vda2 systemd.verity_root_hash=/dev/vda3 systemd.volatile=overlay rd.driver.pre=overlay console=ttysclp0 ro panic=0"
echo "$CMDLINE" > "$WORKDIR/cmdline"
echo "Kernel Command Line:"
echo "  $CMDLINE"

echo "[4/4] Running genprotimg..."
# Remove any existing output file to avoid "error: entity already exists"
rm -f "$OUTPUT_PATH"

GENPROTIMG_ARGS=(
    -i "$WORKDIR/vmlinuz"
    -r "$WORKDIR/initramfs"
    -p "$WORKDIR/cmdline"
    -o "$OUTPUT_PATH"
)

for key in "${RESOLVED_HOST_KEYS[@]}"; do
    GENPROTIMG_ARGS+=(-k "$key")
done

if [[ $NO_VERIFY -eq 1 ]]; then
    GENPROTIMG_ARGS+=(--no-verify)
elif [[ ${#RESOLVED_CERTS[@]} -gt 0 ]]; then
    for c in "${RESOLVED_CERTS[@]}"; do
        GENPROTIMG_ARGS+=(--cert "$c")
    done
else
    GENPROTIMG_ARGS+=(--no-verify)
fi

genprotimg "${GENPROTIMG_ARGS[@]}"

echo "Generated SE boot image: $OUTPUT_PATH ($(du -h "$OUTPUT_PATH" | awk '{print $1}'))"

# ── Optional: Write SE boot image into disk PReP partition (vda1) ──────────────
if [[ $WRITE_TO_DISK -eq 1 ]]; then
    TARGET_DISK="$INPUT_IMAGE"
    if [[ -n "$DISK_OUT" && "$DISK_OUT" != "$INPUT_IMAGE" ]]; then
        echo "Copying $INPUT_IMAGE to $DISK_OUT..."
        cp "$INPUT_IMAGE" "$DISK_OUT"
        TARGET_DISK="$DISK_OUT"
    fi

    echo "----------------------------------------------------------------"
    echo " Copying SE image onto the ext4 /boot-se partition of $TARGET_DISK..."

    # Identify the first partition (vda1/sda1) — the plain ext4 /boot-se
    # partition created by the kickstart (Bug 19).
    BOOT_PART=$(guestfish --ro -a "$TARGET_DISK" run : list-partitions | grep -E 'vda1|sda1' | head -1 || true)
    if [[ -z "$BOOT_PART" ]]; then
        BOOT_PART=$(guestfish --ro -a "$TARGET_DISK" run : list-partitions | head -1)
    fi

    echo "Target /boot-se partition: $BOOT_PART"

    # Copy the .protvirt as a regular file onto the ext4 /boot-se filesystem.
    # Mount at / (overlays the appliance root for this one-shot upload); the
    # filesystem root of vda1 IS /boot-se, so uploading to /<file> lands at
    # /boot-se/<file> in the VM. /tmp and /mnt do not exist in the guestfs
    # appliance, so they cannot be used as mountpoints. mount is issued inside
    # the run session (not via -m on the CLI) to avoid "this function can only
    # be called in the config state".
    # vda2 (root) and vda3 (verity hash) are untouched, preserving dm-verity integrity.
    # Boot via direct-kernel boot: libvirt <kernel> points at a host copy of the .protvirt
    # with roothash= on the kernel cmdline.
    guestfish -a "$TARGET_DISK" run : \
        mount "$BOOT_PART" "/" : \
        upload "$OUTPUT_PATH" "/$(basename "$OUTPUT_PATH")"

    SE_KERNEL_PATH="/boot-se/$(basename "$OUTPUT_PATH")"
    echo "Installed .protvirt file into $SE_KERNEL_PATH on $TARGET_DISK."
    echo "================================================================"
    echo " All-in-One Self-Contained SE QCOW2 Image Created Successfully!"
    echo " Output Image : $TARGET_DISK"
    echo " SE kernel    : $SE_KERNEL_PATH (file inside /boot-se of the qcow2)"
    echo " Boot with    : <kernel>/path/to/$(basename "$OUTPUT_PATH")</kernel> on the host"
    echo "              : plus roothash=$ROOTHASH on the kernel cmdline"
    echo "================================================================"
else
    echo "================================================================"
    echo " IBM Secure Execution Image Created Successfully!"
    echo " Output: $OUTPUT_PATH"
    echo "================================================================"
fi
