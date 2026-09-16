# How to create a dm-verity CoCo PodVM image for s390x

This document mirrors the x86_64 workflow described in [`README.md`](../README.md) but covers every
s390x-specific difference in full.

---

## Architecture differences vs x86_64

| Concern | x86_64 | s390x |
|---|---|---|
| Firmware / boot | UEFI + shim + EFI System Partition | **zipl** bootloader + PReP boot partition |
| Secure Boot signing | `sbsigntools` / UKI addon `.extra.d` | Not used — IBM Secure Execution uses a different trust chain |
| Roothash delivery | UKI addon in ESP (`verity.addon.efi`) | Injected into BLS entry `options` line, `zipl` re-run |
| Root partition GUID | `4f68bce3-e8cd-4db1-96e7-fbcaf984b709` | `08a7acea-624c-4a20-91e8-6e0fa67d23f9` |
| `systemd-repart` verity type | `root-x86-64-verity` | `root-s390x-verity` |
| Disk device in VM | `sda` (SCSI) | `vda` (virtio-blk) |
| Serial console | `ttyS0` | `ttysclp0` |
| NVIDIA drivers | Installed | Not applicable (NVIDIA has no s390x drivers) |
| Build host requirement | Any x86_64 host | **Must be an s390x host** (virt-customize uses native KVM) |

---

## Step 1 — Install a base RHEL 10 s390x image with the kickstart

The kickstart [`helpers/rhel10-s390x-dm-root.ks`](rhel10-s390x-dm-root.ks) produces a minimal image
with the correct partition layout for dm-verity:

- **vda1** — PReP boot partition (4 MiB, required by zipl)
- **vda2** — ext4 root partition, typed with the s390x Discoverable Partitions GUID

Run the installer on an **s390x KVM host**:

Use the automated wrapper script — no manual steps required:

```bash
export ORG_ID=<your-rhsm-org-id>
export ACTIVATION_KEY=<your-activation-key>

# Optional overrides (all have defaults):
# export ISO_PATH=/path/to/RHEL-10.2-s390x-dvd1.iso
# export OUTPUT_DIR=/path/to/output/dir
# export OUTPUT_NAME=rhel10-s390x-base.qcow2

helpers/build-s390x-base-image.sh
```

The script runs `virt-install` with `--noautoconsole --wait -1` so it blocks silently until the VM powers off. `ORG_ID` and `ACTIVATION_KEY` are passed into the kickstart via kernel cmdline (`inst.ks.org_id=` / `inst.ks.activation_key=`) so `%post` can register with RHSM, install network-only packages, unregister, and deprovision — all without any interaction.

Output disk is written to `$OUTPUT_DIR/$OUTPUT_NAME` (default: `../output/rhel10-s390x-base.qcow2`).

---

## Step 2 — Optional: make custom modifications to the base image

Mount and modify the image before applying CoCo components, e.g.:

```bash
virt-customize -a ~/.local/share/libvirt/images/rhel10-s390x-base.qcow2 \
    --run-command "your-custom-script.sh"
```

---

## Step 3 — Build the s390x build container

```bash
# On an s390x host:
sudo podman build -t coco-podvm-s390x -f Dockerfile.s390x .
```

If the host is not subscribed to RHSM, pass subscription credentials:

```bash
sudo -E podman build -t coco-podvm-s390x \
    --secret=id=activation_key,env=ACTIVATION_KEY \
    --secret=id=org_id,env=ORG_ID \
    -f Dockerfile.s390x .
```

---

## Step 4 — Export variables

```bash
# Mandatory
export QCOW2=~/.local/share/libvirt/images/rhel10-s390x-base.qcow2

# Optional — override the CoCo payload registry references
# export PODVM_BINARY=quay.io/...
# export PAUSE_BUNDLE=quay.io/...

# Optional — set a root password for debugging
# export ROOT_PASSWORD=mypassword
```

---

## Step 5 — Run the container to apply CoCo components and dm-verity

```bash
sudo -E podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    -v /lib/modules:/lib/modules:ro,Z \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    localhost/coco-podvm-s390x
```

The container runs [`scripts/create-verity-podvm-s390x.sh`](../scripts/create-verity-podvm-s390x.sh)
which:
1. Calls [`scripts/coco/coco-components-s390x.sh`](../scripts/coco/coco-components-s390x.sh) — pulls
   the CoCo payload and installs it via `virt-customize`
2. Calls [`scripts/verity/verity-s390x.sh`](../scripts/verity/verity-s390x.sh) — creates the verity
   hash partition, captures the roothash, writes it into the BLS boot entries and re-runs `zipl`

The input qcow2 is modified in-place. On success it is a dm-verity protected CoCo PodVM image.

---

## Environment variables reference

### `create-verity-podvm-s390x.sh`

| Variable | Required | Description | Default |
|---|---|---|---|
| `WORK_FOLDER` | no | Scratch working directory | `mktemp -d` |
| `RESIZE_DISK` | no | Grow disk before verity | `yes` |
| `NBD_DEV` | no | `/dev/nbd$NBD_DEV` index | `0` |
| `ROOT_PARTITION_UUID` | no | GPT root type GUID | `08a7acea-624c-4a20-91e8-6e0fa67d23f9` |
| `PODVM_BINARY` | no | Registry for podvm binary | default payload ref |
| `PODVM_BINARY_LOCATION` | no | Path inside container | `/podvm-binaries.tar.gz` |
| `PAUSE_BUNDLE` | no | Registry for pause bundle | default payload ref |
| `PAUSE_BUNDLE_LOCATION` | no | Path inside container | `/pause-bundle.tar.gz` |
| `ROOT_PASSWORD` | no | Root password for debugging | disabled |
| `ACTIVATION_KEY` + `ORG_ID` | no | RHSM subscription credentials | — |

---

## Troubleshooting

**`virt-customize` fails with "unable to create appliance"**
The build container must run on a native s390x KVM host. Cross-arch emulation is not supported by
libguestfs for this workflow.

**zipl fails: "No boot entries found"**
`kernel-uki-virt` must be installed in the image and `kernel-install` must have run, which creates
the BLS entries under `/boot/loader/entries/`. Confirm with:
```bash
virt-ls -a disk.qcow2 /boot/loader/entries/
```

**roothash is empty after `systemd-repart`**
The root partition must carry the s390x Discoverable Partitions GUID
(`08a7acea-624c-4a20-91e8-6e0fa67d23f9`). Check with:
```bash
modprobe nbd
qemu-nbd -c /dev/nbd0 -f qcow2 disk.qcow2
lsblk -o NAME,PARTTYPE -r /dev/nbd0
qemu-nbd --disconnect /dev/nbd0
```
If the GUID is wrong, the kickstart `%post` section sets it via `sfdisk --part-type`.
