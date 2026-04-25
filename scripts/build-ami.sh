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
require_cmd crane parted losetup mkfs.ext4 mkfs.fat grub-install grub-mkconfig aws

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
# crane export flattens the image layers into a single tar stream
crane export --platform linux/amd64 "$(cat "$REPO_ROOT/dist/image-ref" 2>/dev/null || echo foxi:latest)" - \
  | tar x -C "$ROOTFS_DIR" \
  || {
    # Fallback: load from the OCI tar and use the first x86_64 image
    crane push "$IMAGE_TAR" localhost:5000/foxi:latest 2>/dev/null \
      || docker load < "$IMAGE_TAR"
    crane export --platform linux/amd64 localhost:5000/foxi:latest - \
      | tar x -C "$ROOTFS_DIR"
  }

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
for fs in proc sys dev dev/pts; do
  mkdir -p "$ROOTFS_DIR/$fs"
  mount --bind "/$fs" "$ROOTFS_DIR/$fs"
done

KVER=$(cat "$ROOTFS_DIR/boot/kernel-version" 2>/dev/null \
       || ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1 \
       || err "Cannot determine kernel version")
echo "Kernel version: $KVER"

# Install for x86_64-efi; add --target=i386-pc for BIOS hybrid if desired
chroot "$ROOTFS_DIR" grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=foxi \
  --recheck \
  --no-floppy

cat > "$ROOTFS_DIR/etc/default/grub" << EOF
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="Foxi Linux"
# EC2 serial console (ttyS0 at 115200) + standard VGA
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 console=tty1 net.ifnames=0 biosdevname=0 nvme_core.io_timeout=4294967295"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
EOF

chroot "$ROOTFS_DIR" grub-mkconfig -o /boot/efi/EFI/foxi/grub.cfg

# Unmount special filesystems
for fs in dev/pts dev sys proc; do
  umount "$ROOTFS_DIR/$fs"
done

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
      \"DeleteOnTermination\":true,
      \"Encrypted\":false
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

mkdir -p "$REPO_ROOT/dist"
echo "$AMI_ID" > "$REPO_ROOT/dist/ami-id.txt"
echo ""
echo "AMI ID: $AMI_ID"
echo "AMI Name: $AMI_NAME"
echo "Kernel: $KVER"
