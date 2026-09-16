#!/bin/bash
# s390x variant of coco-components.sh
# Installs CoCo guest components into a given s390x disk image via virt-customize.
#
# Differences from the x86_64 version:
#   - Calls script-disk-mods-s390x.sh  (no shim CSV, no NVIDIA)
#   - Calls podvm_maker-s390x.sh       (s390x CentOS mirror, ttysclp0 console)

INPUT_IMAGE=$1

SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname "$0")}
SCRIPT_FOLDER=$(realpath "$SCRIPT_FOLDER")

PODVM_BINARY_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:15d70ba45e3263be545254060674e93fbdef3922480f9c3c80381c599ca1cb67
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:15d70ba45e3263be545254060674e93fbdef3922480f9c3c80381c599ca1cb67
PAUSE_BUNDLE_LOCATION_DEF=/pause-bundle.tar.gz

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "Extract and install all CoCo guest components into a given s390x disk image."
    echo ""
    echo "Options (define them as variables):"
    echo "ARTIFACTS_FOLDER:      optional  - podvm binaries/pause bundle location. Default: $SCRIPT_FOLDER/coco/podvm"
    echo "PODVM_BINARY:          optional  - registry containing podvm binary. Default: $PODVM_BINARY_DEF"
    echo "PODVM_BINARY_LOCATION: optional  - path inside container for podvm binary. Default: $PODVM_BINARY_LOCATION_DEF"
    echo "PAUSE_BUNDLE:          optional  - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF"
    echo "PAUSE_BUNDLE_LOCATION: optional  - path inside container for pause bundle. Default: $PAUSE_BUNDLE_LOCATION_DEF"
    echo "ROOT_PASSWORD:         optional  - set root password. Default: disabled"
}

PODVM_BINARY=${PODVM_BINARY:-"$PODVM_BINARY_DEF"}
PODVM_BINARY_LOCATION=${PODVM_BINARY_LOCATION:-"$PODVM_BINARY_LOCATION_DEF"}
PAUSE_BUNDLE=${PAUSE_BUNDLE:-"$PAUSE_BUNDLE_DEF"}
PAUSE_BUNDLE_LOCATION=${PAUSE_BUNDLE_LOCATION:-"$PAUSE_BUNDLE_LOCATION_DEF"}
ARTIFACTS_FOLDER=${ARTIFACTS_FOLDER:-"$SCRIPT_FOLDER/coco/podvm"}

if [ -z "${INPUT_IMAGE}" ]; then
    local_help
    exit 1
fi

if [[ "$INPUT_IMAGE" == "help" ]]; then
    local_help
    exit 0
fi

function print_params()
{
    echo ""
    echo "INPUT_IMAGE:           $INPUT_IMAGE"
    echo "SCRIPT_FOLDER:         $SCRIPT_FOLDER"
    echo "ARTIFACTS_FOLDER:      $ARTIFACTS_FOLDER"
    echo "PODVM_BINARY:          $PODVM_BINARY"
    echo "PODVM_BINARY_LOCATION: $PODVM_BINARY_LOCATION"
    echo "PAUSE_BUNDLE:          $PAUSE_BUNDLE"
    echo "PAUSE_BUNDLE_LOCATION: $PAUSE_BUNDLE_LOCATION"
    echo "ROOT_PASSWORD:         $ROOT_PASSWORD"
    echo ""
}

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

print_params

export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export DEST_PATH=$ARTIFACTS_FOLDER
"$ARTIFACTS_FOLDER/get-artifacts.sh"

# Build luks-config.tar.gz from the luks-scratch tree
"$ARTIFACTS_FOLDER/luks-scratch/build.sh"

echo ""
ls "$ARTIFACTS_FOLDER"
echo ""

EXTRA_ARGS=""
SM_REGISTER=()
[[ -n "$ROOT_PASSWORD" ]] && EXTRA_ARGS=" --root-password password:${ROOT_PASSWORD} "
[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && \
    SM_REGISTER=(--run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}")

# virt-customize on s390x: the appliance is built for the host arch so this
# must run on an s390x host (or an s390x KVM guest used as a build machine).
#
# Note: --upload is used instead of --copy-in for the payload tarballs.
# --copy-in wraps files in a host-side tar stream before sending via the
# libguestfs tar_in RPC; on this host (libguestfs-1.58.1, RHEL 10 s390x)
# that mechanism fails for large files (tar_in = -1, cancellation sent).
# --upload uses a direct file transfer protocol that does not involve tar
# and works reliably regardless of file size.
virt-customize --memsize 8192 \
    "${SM_REGISTER[@]}" \
    --run "$ARTIFACTS_FOLDER/script-disk-mods-s390x.sh" \
    --upload "$ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/podvm-binaries.tar.gz" \
    --upload "$ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/pause-bundle.tar.gz" \
    --upload "$ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/luks-config.tar.gz" \
    --run "$ARTIFACTS_FOLDER/podvm_maker-s390x.sh" \
    ${EXTRA_ARGS} \
    -a "$INPUT_IMAGE"

[[ ${#SM_REGISTER[@]} -gt 0 ]] && \
    virt-customize --memsize 8192 --run-command "subscription-manager unregister" -a "$INPUT_IMAGE" || true
