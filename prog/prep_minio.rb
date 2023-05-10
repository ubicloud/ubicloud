# frozen_string_literal: true

class Prog::PrepMinio < Prog::Base
  subject_is :minio_node

  def start
    minio_node.sshable.cmd(<<SH)
set -euo pipefail
DEVICE="/dev/loop10"
MOUNT_POINT="/storage"
IMG_FILE="/minio.img"

sudo wget 'https://ubicloud-minio.s3.dualstack.eu-central-1.amazonaws.com/minio_20230413030807.0.0_amd64.deb' -P /home/rhizome/
sudo apt install /home/rhizome/minio_20230413030807.0.0_amd64.deb
sudo dd if=/dev/zero of="$IMG_FILE" bs=3M count=1024
if ! losetup "$DEVICE" | grep -q "$IMG_FILE"; then
  sudo losetup "$DEVICE" "$IMG_FILE"
fi

if ! lsblk -f "$DEVICE" | grep -q xfs; then
  sudo mkfs.xfs "$DEVICE"
fi
sudo mkdir -p /storage/minio
if mountpoint -q "$MOUNT_POINT"; then
  echo "Device already mounted at $MOUNT_POINT"
  exit 0
fi
sudo mount "$DEVICE" "$MOUNT_POINT"
SH
    pop "prepped minio node"
  end
end
