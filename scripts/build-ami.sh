#!/usr/bin/env bash
# Convert the apko OCI image into an EC2 AMI.
#
# Prerequisites (installed on the build host):
#   parted, losetup, mkfs.ext4, mkfs.fat, grub-mkstandalone, aws CLI, python3
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
AMI_NAME="${AMI_NAME:-foxi-$(date -u +%Y%m%d-%H%M)}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

WORK_DIR="$(mktemp -d /tmp/foxi-ami-XXXXXX)"
ROOTFS_DIR="$WORK_DIR/rootfs"
IMAGE_FILE="$WORK_DIR/foxi.raw"
LOOP_DEV=""

err() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  set +e
  [ -d "$ROOTFS_DIR/proc" ]    && umount "$ROOTFS_DIR/proc"    2>/dev/null
  [ -d "$ROOTFS_DIR/sys"  ]    && umount "$ROOTFS_DIR/sys"     2>/dev/null
  [ -d "$ROOTFS_DIR/dev/pts" ] && umount "$ROOTFS_DIR/dev/pts" 2>/dev/null
  [ -d "$ROOTFS_DIR/dev"  ]    && umount "$ROOTFS_DIR/dev"     2>/dev/null
  [ -d "$ROOTFS_DIR/boot/efi" ] && umount "$ROOTFS_DIR/boot/efi" 2>/dev/null
  [ -d "$ROOTFS_DIR" ]          && umount "$ROOTFS_DIR"         2>/dev/null
  [ -n "$LOOP_DEV" ]            && losetup -d "$LOOP_DEV"       2>/dev/null
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

# GPT: 512 MiB EFI System Partition + root on the rest.
parted -s "$IMAGE_FILE" \
  mklabel gpt \
  mkpart esp  fat32  1MiB  513MiB \
  set 1 esp on \
  mkpart root ext4  513MiB 100%

LOOP_DEV=$(losetup --find --show --partscan "$IMAGE_FILE")
echo "Loop device: $LOOP_DEV"
# Allow udev to create the partition devices before we format them.
partprobe "$LOOP_DEV" 2>/dev/null || true
udevadm settle           2>/dev/null || true

# ── 2. Format partitions ─────────────────────────────────────────────────────
mkfs.fat -F32 -n EFI  "${LOOP_DEV}p1"
mkfs.ext4 -L root -q  "${LOOP_DEV}p2"

# ── 3. Mount and populate rootfs ─────────────────────────────────────────────
mkdir -p "$ROOTFS_DIR"
mount "${LOOP_DEV}p2" "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR/boot/efi"
mount "${LOOP_DEV}p1" "$ROOTFS_DIR/boot/efi"

echo "==> Extracting OCI image to rootfs"
# Walk the OCI index → manifest → layers and extract each layer directly.
# This avoids needing crane or a local registry.
# Note: --no-same-owner strips ownership so we restore ec2-user's homedir below.
python3 - "$IMAGE_TAR" "$ROOTFS_DIR" << 'PYEOF'
import json, subprocess, sys, tarfile

image_tar = sys.argv[1]
rootfs    = sys.argv[2]

with tarfile.open(image_tar) as outer:
    index     = json.load(outer.extractfile("index.json"))
    mf_digest = next(
        m["digest"] for m in index["manifests"]
        if m.get("platform", {}).get("architecture", "amd64") == "amd64"
    )
    manifest  = json.load(outer.extractfile(mf_digest))
    for layer_desc in manifest["layers"]:
        layer_name = layer_desc["digest"].split(":", 1)[1] + ".tar.gz"
        layer_data = outer.extractfile(layer_name).read()
        subprocess.run(
            ["tar", "xz", "-C", rootfs, "--no-same-owner"],
            input=layer_data, check=True
        )
PYEOF

# ── 4. Write config files into rootfs ────────────────────────────────────────

# --no-same-owner maps all extracted files to root; restore ec2-user's home so
# sshd StrictModes doesn't reject publickey auth due to wrong ownership.
chown 1000:1000 "$ROOTFS_DIR/home/ec2-user"

# Wolfi's openrc-init lives at /usr/bin/openrc-init; the kernel needs /sbin/init.
ln -sf /usr/bin/openrc-init "$ROOTFS_DIR/sbin/init"

# Wolfi package repository so `apk add <pkg>` works on the running instance.
mkdir -p "$ROOTFS_DIR/etc/apk"
printf 'https://packages.wolfi.dev/os\n' > "$ROOTFS_DIR/etc/apk/repositories"

# sshd hardening
mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
install -Dm600 /dev/stdin "$ROOTFS_DIR/etc/ssh/sshd_config.d/50-cloud.conf" << 'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AuthorizedKeysFile .ssh/authorized_keys
UseDNS no
EOF

# ec2-user can sudo without a password
mkdir -p "$ROOTFS_DIR/etc/sudoers.d"
install -Dm440 /dev/stdin "$ROOTFS_DIR/etc/sudoers.d/ec2-user" << 'EOF'
ec2-user ALL=(ALL) NOPASSWD:ALL
EOF

# apko creates ec2-user in /etc/passwd but writes no /etc/shadow entry.
# OpenSSH checks shadow even with UsePAM no (account expiry/lock check), and
# login(1) requires a shadow entry for password auth on the serial console.
# Add the entry here with a known password hash.
_HASH=$(openssl passwd -6 "foxi")
_DAYS=$(( $(date +%s) / 86400 ))
if grep -q "^ec2-user:" "$ROOTFS_DIR/etc/shadow" 2>/dev/null; then
    awk -v h="$_HASH" 'BEGIN{FS=OFS=":"} /^ec2-user:/{$2=h}1' \
      "$ROOTFS_DIR/etc/shadow" > "$ROOTFS_DIR/etc/shadow.tmp"
    mv "$ROOTFS_DIR/etc/shadow.tmp" "$ROOTFS_DIR/etc/shadow"
else
    echo "ec2-user:${_HASH}:${_DAYS}:0:99999:7:::" >> "$ROOTFS_DIR/etc/shadow"
fi
chmod 0640 "$ROOTFS_DIR/etc/shadow"

# EC2 init: IMDSv2 SSH-key injection + root filesystem resize on first boot.
install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/ec2-init" << 'SCRIPT'
#!/bin/sh
set -e
log() { echo "ec2-init: $*" > /dev/ttyS0 2>/dev/null || true; }

log "starting"

# Wait up to 60 s for dhcpcd to acquire an address before hitting IMDS.
for i in $(seq 1 60); do
  ip route show default | grep -q default && break
  sleep 1
done
log "network ready (waited ${i}s)"

TOKEN=$(curl -sf --max-time 10 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || true

if [ -n "$TOKEN" ]; then
  log "IMDS token obtained"
  PUBKEY=$(curl -sf --max-time 10 -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key") || true
  if [ -n "$PUBKEY" ]; then
    HOME_DIR=/home/ec2-user
    install -dm700 "$HOME_DIR/.ssh"
    chown ec2-user:ec2-user "$HOME_DIR/.ssh"
    printf '%s\n' "$PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    chown ec2-user:ec2-user "$HOME_DIR/.ssh/authorized_keys"
    log "SSH public key installed"
  else
    log "WARNING: no public key found in IMDS (was a key pair specified at launch?)"
  fi
else
  log "WARNING: could not obtain IMDS token - network may not be ready"
fi

ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || true)
[ -n "$ROOT_DEV" ] && resize2fs "$ROOT_DEV" 2>/dev/null && log "root filesystem resized" || true

touch /var/lib/ec2-init-done
log "complete"
SCRIPT

# OpenRC service: EC2 init (runs once on first boot)
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/ec2-init" << 'SVC'
#!/sbin/openrc-run
description="EC2 instance initialization (SSH keys + disk resize)"
depend() { after localmount dhcpcd; before sshd; }
start() {
  [ -f /var/lib/ec2-init-done ] && return 0
  ebegin "Running EC2 init"
  /usr/local/bin/ec2-init
  eend $?
}
SVC

# OpenRC service: sshd (Wolfi openssh-server doesn't ship an init script)
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/sshd" << 'SVC'
#!/sbin/openrc-run
description="OpenSSH server"
command="/usr/sbin/sshd"
command_args="-D"
command_background=yes
pidfile="/run/sshd.pid"
depend() { need localmount; after ec2-init; }
start_pre() {
  for type in rsa ecdsa ed25519; do
    local key="/etc/ssh/ssh_host_${type}_key"
    [ -f "$key" ] || ssh-keygen -q -t "$type" -N "" -f "$key"
  done
  mkdir -p /run/sshd
}
SVC

# OpenRC service: serial console getty for EC2 Serial Console debugging
install -Dm755 /dev/stdin "$ROOTFS_DIR/etc/init.d/agetty.ttyS0" << 'SVC'
#!/sbin/openrc-run
description="agetty on ttyS0"
command="/usr/bin/getty"
command_args="-L ttyS0 115200 vt100"
command_background=yes
pidfile="/run/agetty.ttyS0.pid"
respawn_delay=1
depend() { after localmount; }
SVC

# Enable services in the default runlevel
mkdir -p "$ROOTFS_DIR/etc/runlevels/default"
for svc in dhcpcd ec2-init sshd agetty.ttyS0; do
  ln -sf "/etc/init.d/$svc" "$ROOTFS_DIR/etc/runlevels/default/$svc" 2>/dev/null || true
done

# ── 5. fstab ─────────────────────────────────────────────────────────────────
# import-snapshot regenerates ext4 UUIDs, so we use device paths instead.
# On EC2 Nitro the root EBS volume is always nvme0n1; our partitions are fixed.
cat > "$ROOTFS_DIR/etc/fstab" << 'EOF'
/dev/nvme0n1p2  /          ext4   defaults,noatime,discard  0 1
/dev/nvme0n1p1  /boot/efi  vfat   defaults                  0 2
tmpfs           /tmp       tmpfs  defaults,nosuid,nodev      0 0
EOF

# ── 6. Install GRUB (self-contained UEFI binary) ─────────────────────────────
echo "==> Installing GRUB"

KVER=$(cat "$ROOTFS_DIR/boot/kernel-version" 2>/dev/null \
       || ls "$ROOTFS_DIR/usr/lib/modules/" 2>/dev/null | sort -V | tail -1 \
       || err "Cannot determine kernel version")
echo "Kernel version: $KVER"

VMLINUZ=$(find "$ROOTFS_DIR/boot" -name "vmlinuz-*" | sort -V | tail -1)
[ -n "$VMLINUZ" ] || err "Cannot find kernel image in rootfs"
VMLINUZ_REL="${VMLINUZ#$ROOTFS_DIR}"

GRUB_CFG=$(mktemp)
cat > "$GRUB_CFG" << EOF
set timeout=1
set default=0

serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input  serial console
terminal_output serial console

menuentry "Foxi Linux ${KVER}" {
  insmod part_gpt
  insmod ext2
  set root=(hd0,gpt2)
  linux  ${VMLINUZ_REL} root=/dev/nvme0n1p2 rw ip=dhcp console=tty1 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 nvme_core.io_timeout=4294967295
}
EOF

mkdir -p "$ROOTFS_DIR/boot/grub"
cp "$GRUB_CFG" "$ROOTFS_DIR/boot/grub/grub.cfg"

# grub-mkstandalone embeds all modules + grub.cfg into a single self-contained
# BOOTX64.EFI, avoiding the shim chain that grub-install creates.
mkdir -p "$ROOTFS_DIR/boot/efi/EFI/BOOT"
grub-mkstandalone \
  --format=x86_64-efi \
  --output="$ROOTFS_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$GRUB_CFG"
rm -f "$GRUB_CFG"

echo "EFI binary: $(du -sh "$ROOTFS_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" | cut -f1)"

# ── 7. Finalize and unmount ───────────────────────────────────────────────────
umount "$ROOTFS_DIR/boot/efi"
umount "$ROOTFS_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── 8. Upload raw image to S3 ─────────────────────────────────────────────────
# import-image only supports gzip for VMDK, not RAW — upload uncompressed.
# The image is sparse so the S3 transfer is fast despite the nominal 8 GB size.
S3_KEY="foxi/images/${AMI_NAME}.raw"
echo "==> Uploading to s3://${S3_BUCKET}/${S3_KEY}"
aws s3 cp "$IMAGE_FILE" "s3://${S3_BUCKET}/${S3_KEY}" \
  --region "$AWS_REGION" \
  --expected-size "$(stat -c%s "$IMAGE_FILE")"

# ── 9. Import raw disk as EBS snapshot ───────────────────────────────────────
# import-snapshot has no kernel-version validation (unlike import-image).
# With an uncompressed RAW upload the snapshot contains real disk bytes + GPT,
# so EC2 Nitro EFI correctly enumerates partitions on boot.
echo "==> Importing snapshot (10-15 minutes)"
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
  echo "  Status: ${STATUS}  Progress: ${PROGRESS:-0}%  ${MSG:-}"
  [ "$STATUS" = "completed" ] && break
  [ "$STATUS" = "error" ]     && err "Snapshot import failed: $MSG"
  sleep 30
done

SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
  --region "$AWS_REGION" \
  --import-task-ids "$IMPORT_TASK" \
  --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
  --output text)
{ [ -n "$SNAPSHOT_ID" ] && [ "$SNAPSHOT_ID" != "None" ]; } || err "Could not get snapshot ID"
echo "Snapshot: $SNAPSHOT_ID"

# ── 10. Register AMI ───────────────────────────────────────────────────────────
echo "==> Registering AMI"
AMI_ID=$(aws ec2 register-image \
  --region "$AWS_REGION" \
  --name "$AMI_NAME" \
  --description "Foxi Linux - kernel ${KVER}, Wolfi userspace" \
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
echo "AMI: $AMI_ID"

# ── 11. Tag AMI and snapshot ──────────────────────────────────────────────────
aws ec2 create-tags \
  --region "$AWS_REGION" \
  --resources "$AMI_ID" "$SNAPSHOT_ID" \
  --tags \
    "Key=Name,Value=${AMI_NAME}" \
    "Key=KernelVersion,Value=${KVER}" \
    "Key=ImageTag,Value=${IMAGE_TAG}" \
    "Key=BuildDate,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "Key=ManagedBy,Value=foxi"

# ── 11. Make AMI and snapshot public ─────────────────────────────────────────
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

# ── 12. Rotate: keep only 2 most recent ManagedBy=foxi AMIs ─────────────────
echo "==> Rotating old AMIs (keeping 2 most recent)"
OLD_AMI_IDS=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --filters "Name=tag:ManagedBy,Values=foxi" \
  --query 'sort_by(Images, &CreationDate)[:-2].ImageId' \
  --output text)

if [ -z "$OLD_AMI_IDS" ] || [ "$OLD_AMI_IDS" = "None" ]; then
  echo "  Nothing to rotate."
else
  for old_ami in $OLD_AMI_IDS; do
    OLD_SNAPS=$(aws ec2 describe-images \
      --region "$AWS_REGION" \
      --image-ids "$old_ami" \
      --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
      --output text 2>/dev/null || true)
    echo "  Deregistering $old_ami"
    aws ec2 deregister-image --region "$AWS_REGION" --image-id "$old_ami" || true
    for snap in $OLD_SNAPS; do
      [ -n "$snap" ] && [ "$snap" != "None" ] || continue
      echo "  Deleting snapshot $snap"
      aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap" || true
    done
  done
fi

# ── Done ─────────────────────────────────────────────────────────────────────
mkdir -p "$REPO_ROOT/dist"
echo "$AMI_ID" > "$REPO_ROOT/dist/ami-id.txt"
echo ""
echo "AMI ID:   $AMI_ID  (public)"
echo "AMI Name: $AMI_NAME"
echo "Kernel:   $KVER"
echo "Region:   $AWS_REGION"
echo ""
echo "Launch with:"
echo "  aws ec2 run-instances --image-id $AMI_ID --region $AWS_REGION \\"
echo "    --instance-type t3.micro --key-name <your-key> \\"
echo "    --security-group-ids <sg-id> --subnet-id <subnet-id>"
