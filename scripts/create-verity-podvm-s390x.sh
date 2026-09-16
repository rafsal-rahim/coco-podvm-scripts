#!/bin/bash
set -e

# Orchestrator for building a CoCo PodVM disk image on s390x.
# Mirrors create-verity-podvm.sh but wires up the s390x-specific
# coco-components and verity scripts.

INPUT_IMAGE=$1

here=$(pwd)
SCRIPT_FOLDER=$(dirname "$0")
SCRIPT_FOLDER=$(realpath "$SCRIPT_FOLDER")

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "Takes an s390x RHEL 10 disk image and:"
    echo "  1. Installs CoCo guest components (kata-agent, attestation-agent, etc.)"
    echo "  2. Patches BLS boot entries (root=/dev/mapper/root) and re-runs zipl"
    echo "  3. Applies dm-verity to the root partition (veritysetup format)"
    echo "  4. Prints the roothash — supply it to the VM at start time via"
    echo "     kernel cmdline (Kata Containers / cloud-init / Azure custom data)"
    echo ""
    echo "Options (define them as variables):"
    echo ""
    echo "WORK_FOLDER:            optional  - working directory. Default: temp dir in /tmp"
    echo ""
    echo "Verity options:"
    echo "RESIZE_DISK:            optional  - resize disk before applying verity. Default: yes"
    echo "NBD_DEV:                optional  - /dev/nbd\$NBD_DEV to use. Default: 0"
    echo "VERITY_SCRIPT_LOCATION: optional  - path to verity-s390x.sh. Default: \$SCRIPT_FOLDER/verity/verity-s390x.sh"
    echo "ROOT_PARTITION_UUID:    optional  - GPT root type UUID. Default: 08a7acea-624c-4a20-91e8-6e0fa67d23f9"
    echo ""
    echo "CoCo guest options:"
    echo "ARTIFACTS_FOLDER:       optional  - podvm binaries/pause bundle location"
    echo "PODVM_BINARY:           optional  - registry containing podvm binary"
    echo "PODVM_BINARY_LOCATION:  optional  - path inside container for podvm binary"
    echo "PAUSE_BUNDLE:           optional  - registry containing pause bundle"
    echo "PAUSE_BUNDLE_LOCATION:  optional  - path inside container for pause bundle"
    echo "ROOT_PASSWORD:          optional  - set root password. Default: disabled"
    echo ""
    echo "Exiting"
}

if [ -z "${INPUT_IMAGE}" ]; then
    local_help
    exit 1
fi

if [[ "$INPUT_IMAGE" == "help" ]]; then
    local_help
    exit 0
fi

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

VERITY_SCRIPT_LOCATION=${VERITY_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/verity/verity-s390x.sh"}
VERITY_SCRIPT_LOCATION=$(realpath "$VERITY_SCRIPT_LOCATION")

COCO_SCRIPT_LOCATION=${COCO_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/coco/coco-components-s390x.sh"}
COCO_SCRIPT_LOCATION=$(realpath "$COCO_SCRIPT_LOCATION")

function print_params()
{
    echo ""
    echo "WORK_FOLDER:            $WORK_FOLDER"
    echo "INPUT_IMAGE:            $INPUT_IMAGE"
    echo "VERITY_SCRIPT_LOCATION: $VERITY_SCRIPT_LOCATION"
    echo "COCO_SCRIPT_LOCATION:   $COCO_SCRIPT_LOCATION"
    echo ""
}

function error_exit()
{
    echo "$1" 1>&2
    exit 1
}

function get_podvm_image_format()
{
    local image_path="$1"
    echo "Getting format of the PodVM image: ${image_path}"
    PODVM_IMAGE_FORMAT=$(qemu-img info --output json "${image_path}" | jq -r '.format') ||
        error_exit "Failed to get podvm image info"

    if [[ "${image_path}" == *.vhd ]] && [[ "${PODVM_IMAGE_FORMAT}" == "raw" ]]; then
        PODVM_IMAGE_FORMAT="vhd"
    fi

    echo "PodVM image format: ${PODVM_IMAGE_FORMAT}"
    export PODVM_IMAGE_FORMAT
}

function get_input_img_format()
{
    get_podvm_image_format "$1"

    case "${PODVM_IMAGE_FORMAT}" in
    "qcow2") DISK_FORMAT="qcow2" ;;
    "raw")   DISK_FORMAT="raw"   ;;
    "vhd")   DISK_FORMAT="vpc"   ;;
    *)       error_exit "Unsupported image format: ${PODVM_IMAGE_FORMAT}" ;;
    esac

    export DISK_FORMAT
}

function handle_ctrlc()
{
    cd "$here"
    exit 0
}

WORK_FOLDER=${WORK_FOLDER:-$(mktemp -d)}
WORK_FOLDER=$(realpath "$WORK_FOLDER")

print_params

cd "$WORK_FOLDER"

trap handle_ctrlc SIGINT
trap handle_ctrlc EXIT

get_input_img_format "$INPUT_IMAGE"

echo "Applying CoCo guest components (s390x) ..."
export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export ARTIFACTS_FOLDER
export SCRIPT_FOLDER
export ROOT_PASSWORD
"$COCO_SCRIPT_LOCATION" "$INPUT_IMAGE"
echo ""

echo "Applying dm-verity (s390x) ..."
export DISK_FORMAT
export RESIZE_DISK
export NBD_DEV
export VERITY_FOLDER=$WORK_FOLDER
export ROOT_PARTITION_UUID
"$VERITY_SCRIPT_LOCATION" "$INPUT_IMAGE"
echo ""

cd - > /dev/null
rm -rf "$WORK_FOLDER"

echo "Process completed!"
echo "Your s390x disk image now has CoCo components and dm-verity enabled."
