# Kickstart Partition Creation Fix for s390x

## Problem Identified

The s390x kickstart files were failing to create partitions during installation, despite Anaconda reporting successful completion. The issue affected both RHEL 9.7 and RHEL 10 Beta.

## Root Cause

The kickstart files were using Anaconda's automatic partition creation (`part /boot --ondisk=vda --size=1024`) instead of pre-creating partitions with explicit GPT partition types like the x86_64 version does.

**Key difference between x86_64 and s390x kickstarts:**

### x86_64 (working):
```kickstart
%pre --erroronfail
sfdisk --wipe always -X gpt /dev/sda << EOF
2048,1032192,C12A7328-F81F-11D2-BA4B-00A0C93EC93B
,5242880,4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
EOF
%end

part /boot/efi --onpart=sda1 --fstype efi
part / --onpart=sda2 --fstype ext4
```

### s390x (broken - before fix):
```kickstart
ignoredisk --only-use=vda
clearpart --all --initlabel --drives=vda

part /boot --fstype="xfs" --ondisk=vda --size=1024 --label=boot
part / --fstype="xfs" --ondisk=vda --size=1 --grow --label=root
```

The s390x version was missing the `%pre` section that creates the GPT partition table with proper partition type GUIDs.

## Solution

Added a `%pre` section to both s390x kickstart files that:

1. **Creates a GPT partition table** using `sfdisk`
2. **Sets proper partition type GUIDs**:
   - Partition 1 (/boot): `0FC63DAF-8483-4772-8E79-3D69D8477DE4` (Linux filesystem)
   - Partition 2 (/): `5EEAD9A9-FE09-4A1E-A1D7-520D00531306` (Linux root s390x)
3. **Uses `--onpart` instead of `--ondisk`** to tell Anaconda to use pre-created partitions

### Fixed s390x kickstart structure:
```kickstart
ignoredisk --only-use=vda

%pre --erroronfail
# Create GPT partition table with proper partition types for s390x
# Partition 1: /boot (1GB, Linux filesystem)
# Partition 2: / (rest of disk, Linux root s390x)
sfdisk --wipe always -X gpt /dev/vda << EOF
2048,2097152,0FC63DAF-8483-4772-8E79-3D69D8477DE4
,+,5EEAD9A9-FE09-4A1E-A1D7-520D00531306
EOF
%end

part /boot --onpart=vda1 --fstype=xfs
part / --onpart=vda2 --fstype=xfs
```

## Additional Changes

Removed the redundant `sfdisk --part-type` command from the `%post` section since partition types are now set correctly in the `%pre` section.

## Files Modified

1. `helpers/rhel9-dm-root-s390x.ks`
2. `helpers/rhel10-dm-root-s390x.ks`

## Testing

After applying this fix, test with:

```bash
virt-install \
  --name rhel9-s390x-test \
  --memory 8192 \
  --location rhel-9.7-s390x-dvd.iso \
  --disk path=./test.qcow2,format=qcow2,bus=virtio,size=7 \
  --initrd-inject=helpers/rhel9-dm-root-s390x.ks \
  --nographics \
  --extra-args "console=ttysclp0 inst.ks=file:/rhel9-dm-root-s390x.ks" \
  --transient
```

Verify partitions were created:
```bash
virt-filesystems -a test.qcow2 -l
```

Expected output should show:
- `/dev/vda1` - /boot partition (XFS, ~1GB)
- `/dev/vda2` - / partition (XFS, remaining space)

## Why This Works

1. **Explicit partition creation**: By creating partitions in `%pre`, we ensure they exist before Anaconda tries to format them
2. **Correct partition type GUIDs**: The s390x-specific GUID (`5EEAD9A9-FE09-4A1E-A1D7-520D00531306`) is required for proper boot and system recognition
3. **GPT partition table**: Modern systems require GPT, not MBR/MSDOS partition tables
4. **`--onpart` directive**: Tells Anaconda to use existing partitions rather than trying to create new ones

## References

- GPT Partition Type GUIDs: https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
- s390x Linux root GUID: `5EEAD9A9-FE09-4A1E-A1D7-520D00531306`
- x86_64 Linux root GUID: `4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709`