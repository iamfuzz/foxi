#!/usr/bin/env bash
# Convert the apko OCI image into an EC2 AMI.
#
# Prerequisites (installed on the build host):
#   crane, parted, mkfs.ext4, mkfs.fat, grub-install, grub-mkconfig,
#   losetup, aws CLI
#
# Required env vars:
#   S3_BUCKET   - S3 bucket for the raw image upload
#   AWS_REGION  - AWS region for import and AMI registration
#
# Optional env vars:
#   IMAGE_TAR   - path to OCI image tar (default: dist/foxi.tar)
#   IMAGE_SIZE  - disk image size (default: 8G)
#   AMI_NAME    - name for the registered AMI
#   IMAGE_TAG   - version tag for AMI metadata
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_TAR="${IMAGE_TAR:-$REPO_ROOT/dist/foxi.tar}"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set}"
AWS_REGION="${AWS_REGION:?AWS_REGION must be set}"
AMI_NAME="${AMI_NAME:-foxi-$(date -u +%Y%m%d%H%M)}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

WORK_DIR="$(mktemp -d /tmp/foxi-ami-XXXXXX)"
ROOTFS_DIR="$WORK_DIR/rootfs"
IMAGE_FILE="$WORK_DIR/foxi.raw"
LOOP_DEV=""

err() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  set +e
  [ -d "$ROOTFS_DIR/proc" ] && umount "$ROOTFS_DIR/proc" 2>/dev/null
  [ -d "$ROOTFS_DIR/sys"  ] && umount "$ROOTFS_DIR/sys"  2>/dev/null
  [ -d "$ROOTFS_DIR/dev/pts" ] && umount "$ROOTFS_DIR/dev/pts" 2>/dev/null
  [ -d "$ROOTFS_DIR/dev"  ] && umount "$ROOTFS_DIR/dev"  2>/dev/null
  [ -d "$ROOTFS_DIR/boot/efi" ] && umount "$ROOTFS_DIR/boot/efi" 2>/dev/null
  [ -d "$ROOTFS_DIR" ]     && umount "$ROOTFS_DIR" 2>/dev/null
  [ -n "$LOOP_DEV" ]        && losetup -d "$LOOP_DEV" 2>/dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || err "Required command not found: $cmd"
  done
}
require_cmd parted losetup mkfs.ext4 mkfs.fat grub-mkstandalone aws python3

# ── 1. Create raw disk image ─────────────────────────────────────────────────
echo "==> Creating ${IMAGE_SIZE} raw disk image"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"

# GPT with a 512 MiB EFI partition and the rest for root.
# EC2 Nitro supports UEFI; older instances fall back to BIOS via GRUB hybrid.
parted -s "$IMAGE_FILE" \
  mklabel gpt \
  mkpart esp  fat32  1MiB  513MiB \
  set 1 esp on \
  mkpart root ext4  513MiB 100%

LOOP_DEV=$(losetup --find --show --partscan "$IMAGE_FILE")
echo "Loop device: $LOOP_DEV"

# ── 2. Format partitions ─────────────────────────────────────────────────────
mkfs.fat -F32 -n EFI    "${LOOP_DEV}p1"
mkfs.ext4 -L root -q    "${LOOP_DEV}p2"

# ── 3. Mount and populate rootfs ──────────────────────────────────────────────
mkdir -p "$ROOTFS_DIR"
mount "${LOOP_DEV}p2" "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR/boot/efi"
mount "${LOOP_DEV}p1" "$ROOTFS_DIR/boot/efi"

echo "==> Extracting OCI image to rootfs"
# The apko OCI tar stores each layer as a <digest>.tar.gz file inside the outer tar.
# Read the OCI index → manifest → layer list, then stream each layer directly.
# This avoids needing crane or a registry for single-arch images.
python3 - "$IMAGE_TAR" "$ROOTFS_DIR" << 'PYEOF'
import json, subprocess, sys, tarfile

image_tar = sys.argv[1]
rootfs    = sys.argv[2]

with tarfile.open(image_tar) as outer:
    index   = json.load(outer.extractfile("index.json"))
    # Pick the amd64 manifest (first for single-arch, or search by platform)
    mf_digest = next(
        m["digest"] for m in index["manifests"]
        if m.get("platform", {}).get("architecture", "amd64") == "amd64"
    )
    mf_name = mf_digest.replace("sha256:", "sha256:", 1)  # keep as-is; key in tar
    manifest = json.load(outer.extractfile(mf_name))
    for layer_desc in manifest["layers"]:
        layer_digest = layer_desc["digest"]
        # Layer is stored as "<hex>.tar.gz" (without sha256: prefix)
        layer_name = layer_digest.split(":", 1)[1] + ".tar.gz"
        layer_data = outer.extractfile(layer_name).read()
        subprocess.run(
            ["tar", "xz", "-C", rootfs, "--no-same-owner"],
            input=layer_data, check=True
        )
PYEOF

# ── 4a. Write Foxi config files into rootfs ──────────────────────────────────

# Wolfi's openrc-init is at /usr/bin/openrc-init; the kernel looks for /sbin/init
ln -sf /usr/bin/openrc-init "$ROOTFS_DIR/sbin/init"

mkdir -p "$ROOTFS_DIR/etc/apk"
cat > "$ROOTFS_DIR/etc/apk/repositories" << 'EOF'
https://packages.wolfi.dev/os
EOF

mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/50-cloud.conf" << 'EOF'
PermitRootLogin no
PasswordAuthentication no
AuthorizedKeysFile .ssh/authorized_keys
UseDNS no
EOF
chmod 0600 "$ROOTFS_DIR/etc/ssh/sshd_config.d/50-cloud.conf"

# openrc-init does NOT use /etc/inittab (that's busybox init). Console getty
# is handled by the agetty.ttyS0 OpenRC service below.

# Minimal EC2 init: IMDSv2 SSH key injection + disk growth.
# Networking is handled by the dhcpcd OpenRC service (and by ip=dhcp on the
# kernel cmdline for the very first DHCP before dhcpcd starts).
install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/ec2-init" << 'SCRIPT'
#!/bin/sh
set -e

# ── SSH key injection via IMDSv2 ─────────────────────────────────────────────
# Brief wait for dhcpcd to get an address if ec2-init races ahead of it.
sleep 3
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null) || true

if [ -n "$TOKEN" ]; then
  PUBKEY=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key" 2>/dev/null) || true
  if [ -n "$PUBKEY" ]; then
    HOME_DIR=$(getent passwd ec2-user | cut -d: -f6)
    install -dm700 "$HOME_DIR/.ssh"
    chown ec2-user:ec2-user "$HOME_DIR/.ssh"
    echo "$PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    chown ec2-user:ec2-user "$HOME_DIR/.ssh/authorized_keys"
  fi
fi

# ── Root filesystem expansion ─────────────────────────────────────────────────
ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$ROOT_DEV" ]; then
  resize2fs "$ROOT_DEV" 2>/dev/null || true
fi

# Mark done so we don't re-run on every boot
touch /var/lib/ec2-init-done
SCRIPT

# ec2-init OpenRC service
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/ec2-init" << 'SVC'
#!/sbin/openrc-run
description="EC2 instance initialization (SSH keys + disk resize)"
depend() { after localmount dhcpcd; before sshd; }
start() {
  if [ -f /var/lib/ec2-init-done ]; then return 0; fi
  ebegin "Running EC2 init"
  /usr/local/bin/ec2-init
  eend $?
}
SVC

# sshd OpenRC service — Wolfi's openssh-server doesn't ship one
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/sshd" << 'SVC'
#!/sbin/openrc-run
description="OpenSSH server"
command="/usr/bin/sshd"
command_args="-D"
pidfile="/run/sshd.pid"
depend() { need localmount; after ec2-init; }
start_pre() {
  # Generate host keys if missing (first boot)
  for type in rsa ecdsa ed25519; do
    local key="/etc/ssh/ssh_host_${type}_key"
    [ -f "$key" ] || /usr/bin/ssh-keygen -q -t "$type" -N "" -f "$key"
  done
  mkdir -p /run/sshd
}
SVC

# Serial console getty (ttyS0) so EC2 Serial Console works for debugging
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/agetty.ttyS0" << 'SVC'
#!/sbin/openrc-run
description="agetty on ttyS0"
command="/usr/bin/getty"
command_args="-L ttyS0 115200 vt100"
respawn=yes
depend() { after localmount; }
SVC

# Enable services in default runlevel
mkdir -p "$ROOTFS_DIR/etc/runlevels/default"
for svc in dhcpcd ec2-init sshd agetty.ttyS0; do
  ln -sf "/etc/init.d/$svc" "$ROOTFS_DIR/etc/runlevels/default/$svc" 2>/dev/null || true
done

# ── 4. Configure fstab ────────────────────────────────────────────────────────
EFI_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p1")
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p2")

cat > "$ROOTFS_DIR/etc/fstab" << EOF
UUID=$ROOT_UUID  /          ext4   defaults,noatime,discard  0 1
UUID=$EFI_UUID   /boot/efi  vfat   defaults                  0 2
tmpfs            /tmp       tmpfs  defaults,nosuid,nodev      0 0
EOF

# ── 5. Install GRUB ───────────────────────────────────────────────────────────
echo "==> Installing GRUB"

KVER=$(cat "$ROOTFS_DIR/boot/kernel-version" 2>/dev/null \
       || ls "$ROOTFS_DIR/usr/lib/modules/" 2>/dev/null | sort -V | tail -1 \
       || err "Cannot determine kernel version")
echo "Kernel version: $KVER"

VMLINUZ=$(find "$ROOTFS_DIR/boot" -name "vmlinuz-*" | sort -V | tail -1)
[ -n "$VMLINUZ" ] || err "Cannot find kernel image in rootfs"
VMLINUZ_REL="${VMLINUZ#$ROOTFS_DIR}"

# Write grub.cfg — used both as the embedded config and installed on disk
# (so it can be updated on a running instance with grub-mkconfig or manually).
# No initrd: ext4 is built into the kernel; ip=dhcp triggers kernel DHCP early.
GRUB_CFG=$(mktemp)
cat > "$GRUB_CFG" << EOF
set timeout=1
set default=0

serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

menuentry "Foxi Linux ${KVER}" {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
  linux  ${VMLINUZ_REL} root=UUID=${ROOT_UUID} rw ip=dhcp console=ttyS0,115200n8 console=tty1 net.ifnames=0 biosdevname=0 nvme_core.io_timeout=4294967295
}
EOF

mkdir -p "$ROOTFS_DIR/boot/grub"
cp "$GRUB_CFG" "$ROOTFS_DIR/boot/grub/grub.cfg"

# Use grub-mkstandalone to produce a single self-contained BOOTX64.EFI that
# embeds all required modules and the grub.cfg above.  This avoids the shim
# chain and the EFI/BOOT/grub.cfg UUID-search step that grub-install emits,
# both of which have proven unreliable across EC2 firmware versions.
mkdir -p "$ROOTFS_DIR/boot/efi/EFI/BOOT"
grub-mkstandalone \
  --format=x86_64-efi \
  --output="$ROOTFS_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$GRUB_CFG"
rm -f "$GRUB_CFG"

echo "EFI binary: $(du -sh $ROOTFS_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI | cut -f1)"

# ── 6. Finalize and unmount ───────────────────────────────────────────────────
umount "$ROOTFS_DIR/boot/efi"
umount "$ROOTFS_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── 7. Compress and upload to S3 ─────────────────────────────────────────────
S3_KEY="foxi/images/${AMI_NAME}.raw.gz"
echo "==> Compressing image"
gzip -f "$IMAGE_FILE"

echo "==> Uploading to s3://${S3_BUCKET}/${S3_KEY}"
aws s3 cp "${IMAGE_FILE}.gz" "s3://${S3_BUCKET}/${S3_KEY}" \
  --region "$AWS_REGION" \
  --expected-size "$(stat -c%s "${IMAGE_FILE}.gz")"

# ── 8. Import as EC2 snapshot ─────────────────────────────────────────────────
echo "==> Importing snapshot (this takes several minutes)"
IMPORT_TASK=$(aws ec2 import-snapshot \
  --region "$AWS_REGION" \
  --description "Foxi Linux ${AMI_NAME}" \
  --disk-container "Format=RAW,UserBucket={S3Bucket=${S3_BUCKET},S3Key=${S3_KEY}}" \
  --query 'ImportTaskId' --output text)

echo "Import task: $IMPORT_TASK"

while true; do
  read -r STATUS PROGRESS MSG < <(aws ec2 describe-import-snapshot-tasks \
    --region "$AWS_REGION" \
    --import-task-ids "$IMPORT_TASK" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.[Status,Progress,StatusMessage]' \
    --output text)
  echo "  Status: $STATUS  Progress: ${PROGRESS}%  $MSG"
  [ "$STATUS" = "completed" ] && break
  [ "$STATUS" = "error" ]     && err "Snapshot import failed: $MSG"
  sleep 30
done

SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
  --region "$AWS_REGION" \
  --import-task-ids "$IMPORT_TASK" \
  --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
  --output text)
echo "Snapshot: $SNAPSHOT_ID"

# ── 9. Register AMI ───────────────────────────────────────────────────────────
echo "==> Registering AMI"
AMI_ID=$(aws ec2 register-image \
  --region "$AWS_REGION" \
  --name "$AMI_NAME" \
  --description "Foxi Linux - Alpine kernel ${KVER}, Wolfi userspace, Chainguard packages" \
  --architecture x86_64 \
  --virtualization-type hvm \
  --boot-mode uefi-preferred \
  --ena-support \
  --imds-support v2.0 \
  --root-device-name /dev/xvda \
  --block-device-mappings "[{
    \"DeviceName\":\"/dev/xvda\",
    \"Ebs\":{
      \"SnapshotId\":\"${SNAPSHOT_ID}\",
      \"VolumeType\":\"gp3\",
      \"VolumeSize\":8,
      \"DeleteOnTermination\":true
    }
  }]" \
  --query 'ImageId' --output text)

aws ec2 create-tags \
  --region "$AWS_REGION" \
  --resources "$AMI_ID" "$SNAPSHOT_ID" \
  --tags \
    "Key=Name,Value=${AMI_NAME}" \
    "Key=KernelVersion,Value=${KVER}" \
    "Key=ImageTag,Value=${IMAGE_TAG}" \
    "Key=BuildDate,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "Key=ManagedBy,Value=foxi"

# ── 10. Make AMI and snapshot public ─────────────────────────────────────────
echo "==> Making AMI public"
aws ec2 modify-image-attribute \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --launch-permission "Add=[{Group=all}]"

aws ec2 modify-snapshot-attribute \
  --region "$AWS_REGION" \
  --snapshot-id "$SNAPSHOT_ID" \
  --attribute createVolumePermission \
  --operation-type add \
  --group-names all

mkdir -p "$REPO_ROOT/dist"
echo "$AMI_ID" > "$REPO_ROOT/dist/ami-id.txt"
echo ""
echo "AMI ID:   $AMI_ID  (public)"
echo "AMI Name: $AMI_NAME"
echo "Kernel:   $KVER"
echo "Region:   $AWS_REGION"
echo ""
echo "Anyone can launch with:"
echo "  aws ec2 run-instances --image-id $AMI_ID --region $AWS_REGION ..."
