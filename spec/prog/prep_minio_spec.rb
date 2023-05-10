# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PrepMinio do
  subject(:pm) { described_class.new(Strand.new(stack: [{minio_node_id: "bogus"}])) }

  describe "#start" do
    it "exits, after prepping the node with binary and device setup" do
      minio_node = instance_double(MinioNode)
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with(<<SH)
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
      expect(pm).to receive(:minio_node).and_return(minio_node)
      expect(minio_node).to receive(:sshable).and_return(sshable)
      expect(pm).to receive(:pop).with("prepped minio node")
      pm.start
    end
  end
end
