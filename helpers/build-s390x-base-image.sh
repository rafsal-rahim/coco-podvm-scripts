#!/bin/bash
set -e

# Fully automated wrapper around virt-install to build the RHEL 10 s390x
# CoCo PodVM base image using helpers/rhel10-s390x-dm-root.ks.
#
# Handles everything that required manual intervention during development:
#   - Passes ORG_ID + ACTIVATION_KEY into the kickstart %post via kernel cmdline
#   - Uses --noautoconsole --wait -1 so virt-install blocks until the VM
#     powers off (kickstart ends with `poweroff`) — no TTY warning, no hanging
#   - Destroys and undefines the transient domain on completion or error
#   - Writes the output disk to OUTPUT_DIR/rhel10-s390x-base.qcow2

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")

function usage()
{
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Build the RHEL 10 s390x CoCo PodVM base image unattended."
    echo ""
    echo "Options (env vars or flags):"
    echo "  ORG_ID           mandatory  RHSM organisation ID"
    echo "  ACTIVATION_KEY   mandatory  RHSM activation key"
    echo "  ISO_PATH         optional   path to RHEL 10 s390x DVD ISO"
    echo "                              Default: \$REPO_ROOT/RHEL-10.2-s390x-dvd1.iso"
    echo "  OUTPUT_DIR       optional   directory for the output qcow2"
    echo "                              Default: \$REPO_ROOT/../output"
    echo "  OUTPUT_NAME      optional   output filename (no path)"
    echo "                              Default: rhel10-s390x-base.qcow2"
    echo "  DISK_SIZE_GB     optional   disk size in GiB. Default: 7"
    echo "  VM_MEMORY_MB     optional   installer VM RAM in MiB. Default: 8192"
    echo "  VM_NAME          optional   transient VM name. Default: rhel10-s390x-build-\$\$"
    echo ""
    echo "Example:"
    echo "  ORG_ID=<YOUR_ORG_ID> ACTIVATION_KEY=<YOUR_ACTIVATION_KEY> $0"
}

if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# ── Validate mandatory inputs ─────────────────────────────────────────────────
if [[ -z "${ORG_ID:-}" ]]; then
    echo "ERROR: ORG_ID is required." >&2
    usage; exit 1
fi
if [[ -z "${ACTIVATION_KEY:-}" ]]; then
    echo "ERROR: ACTIVATION_KEY is required." >&2
    usage; exit 1
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
ISO_PATH=${ISO_PATH:-"$REPO_ROOT/RHEL-10.2-s390x-dvd1.iso"}
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_ROOT/../output"}
OUTPUT_NAME=${OUTPUT_NAME:-"rhel10-s390x-base.qcow2"}
DISK_SIZE_GB=${DISK_SIZE_GB:-7}
VM_MEMORY_MB=${VM_MEMORY_MB:-8192}
VM_NAME=${VM_NAME:-"rhel10-s390x-build-$$"}
KS_FILE="$SCRIPT_DIR/rhel10-s390x-dm-root.ks"
OUTPUT_DISK="$OUTPUT_DIR/$OUTPUT_NAME"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo ""
echo "=== s390x base image build ==="
echo "ISO_PATH:    $ISO_PATH"
echo "OUTPUT_DISK: $OUTPUT_DISK"
echo "KS_FILE:     $KS_FILE"
echo "VM_NAME:     $VM_NAME"
echo "DISK_SIZE:   ${DISK_SIZE_GB} GiB"
echo "RAM:         ${VM_MEMORY_MB} MiB"
echo ""

if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO not found at $ISO_PATH" >&2
    exit 1
fi

if [[ ! -f "$KS_FILE" ]]; then
    echo "ERROR: Kickstart not found at $KS_FILE" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Remove leftover disk from a previous failed attempt
rm -f "$OUTPUT_DISK"

# ── Cleanup handler ───────────────────────────────────────────────────────────
function cleanup()
{
    local rc=$?
    echo ""
    # Destroy the VM if it is still running (e.g. on Ctrl-C or error)
    if virsh domstate "$VM_NAME" &>/dev/null; then
        echo "Destroying transient VM $VM_NAME ..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
    fi
    if [[ $rc -ne 0 ]]; then
        echo "Build FAILED (exit code $rc)." >&2
    fi
    exit $rc
}
trap cleanup EXIT SIGINT SIGTERM

# ── Run virt-install ──────────────────────────────────────────────────────────
# Key flags:
#   --noautoconsole   suppress the "no TTY" warning; do not try to open console
#   --wait -1         block until the domain shuts off (poweroff in kickstart)
#   --transient       domain is automatically undefined when it shuts off
#
# ORG_ID and ACTIVATION_KEY are passed as custom kernel cmdline parameters
# inst.ks.org_id= and inst.ks.activation_key= — Anaconda preserves all
# inst.ks.* parameters and makes the full cmdline available in /proc/cmdline
# inside the %post environment so the kickstart can read them with sed.

virt-install \
    --virt-type kvm \
    --os-variant rhel10.2 \
    --arch s390x \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY_MB" \
    --location "$ISO_PATH" \
    --disk "path=${OUTPUT_DISK},format=qcow2,bus=virtio,size=${DISK_SIZE_GB}" \
    --initrd-inject "$KS_FILE" \
    --nographics \
    --noautoconsole \
    --wait -1 \
    --extra-args "console=ttysclp0 inst.ks=file:/rhel10-s390x-dm-root.ks inst.ks.org_id=${ORG_ID} inst.ks.activation_key=${ACTIVATION_KEY}" \
    --transient

echo ""
echo "=== Build complete ==="
echo "Output: $OUTPUT_DISK"
ls -lh "$OUTPUT_DISK"
