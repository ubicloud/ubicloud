# frozen_string_literal: true

RSpec.describe SystemParser do
  let(:lsblk_json) do
    '{"blockdevices": [{"name": "nvme0n1","type": "disk","mountpoints": ["/"],"children": [{"name": "nvme0n1p1","type": "part","mountpoints": ["/boot"]},{"name": "nvme0n1p2","type": "part","mountpoints": ["/data"]}]},{"name": "nvme1n1","type": "disk","mountpoints": ["/mnt"],"children": [{"name": "nvme1n1p1","type": "part","mountpoints": ["/mnt/partition1"]}]},{"name": "nvme0n2","type": "disk","mountpoints": null}]}'
  end
  let(:mdstat_content) do
    "Personalities : [raid1] [linear] [multipath] [raid0] [raid6] [raid5] [raid4] [raid10]\n" \
    "md2 : active raid1 nvme1n1p3[1] nvme0n1p3[0]\n465370432 blocks super 1.2 [2/2] [UU]\n" \
    "md0 : active raid1 nvme1n1p1[1] nvme0n1p1[0]\n33520640 blocks super 1.2 [2/2] [UU]\n" \
    "md1 : active raid1 nvme1n1p2[1] nvme0n1p2[0]\n1046528 blocks super 1.2 [2/2] [UU]\n"
  end
  let(:df_output) do
    "Filesystem     Mounted on    1B-blocks        Avail\n" \
    "/dev/md2       /             467909804032    433234698240\n" \
    "/dev/md0       /boot         33520640         1024\n" \
    "/dev/md1       /data         1046528           512\n"
  end

  describe ".get_device_mount_points_from_lsblk_json" do
    context "when the device is present" do
      it "returns the correct mount points for a device" do
        mount_points = described_class.get_device_mount_points_from_lsblk_json(lsblk_json, "nvme0n1")
        expect(mount_points["nvme0n1"]).to contain_exactly("/", "/data")
      end
    end

    context "when the device is not found" do
      it "returns nil" do
        mount_points = described_class.get_device_mount_points_from_lsblk_json(lsblk_json, "nonexistent")
        expect(mount_points["nonexistent"]).to be_nil
      end
    end

    context "when excluding boot and swap mounts" do
      it "excludes boot mount points" do
        mount_points = described_class.get_device_mount_points_from_lsblk_json(lsblk_json, "nvme0n1")
        expect(mount_points["nvme0n1"]).not_to include("/boot")
      end
    end

    context "when mountpoints is nil for a device" do
      it "handles nil mountpoints without error" do
        lsblk_json_with_nil_mountpoints = '{"blockdevices": [{"name": "nvme0n2", "type": "disk", "mountpoints": null}]}'
        mount_points = described_class.get_device_mount_points_from_lsblk_json(lsblk_json_with_nil_mountpoints, "nvme0n2")
        expect(mount_points["nvme0n2"]).to be_nil
      end
    end
  end

  describe ".extract_underlying_raid_devices_from_mdstat" do
    context "when raid device is found" do
      it "returns the underlying raid devices" do
        devices = described_class.extract_underlying_raid_devices_from_mdstat(mdstat_content, "/dev/md2")
        expect(devices).to contain_exactly("nvme1n1", "nvme0n1")
      end
    end

    context "when raid device is not found" do
      it "returns an empty array" do
        devices = described_class.extract_underlying_raid_devices_from_mdstat(mdstat_content, "/dev/md3")
        expect(devices).to be_empty
      end
    end
  end

  describe ".extract_disk_info_from_df" do
    context "when df output is correct" do
      it "parses the df output and returns disk information" do
        disks = described_class.extract_disk_info_from_df(df_output)
        expect(disks.length).to eq(3)
        expect(disks[0].unix_device).to eq("/dev/md2")
        expect(disks[1].unix_device).to eq("/dev/md0")
        expect(disks[2].unix_device).to eq("/dev/md1")
      end
    end

    context "when df output has an invalid format for header" do
      it "raises an error" do
        invalid_df_output = "Invalid df output"
        expect {
          described_class.extract_disk_info_from_df(invalid_df_output)
        }.to raise_error(RuntimeError).with_message("BUG: df header parse failed")
      end
    end

    context "when df output has an invalid format for data" do
      it "raises an error" do
        invalid_df_output = "Filesystem     Mounted on    1B-blocks        Avail\nIncorrectData"
        expect {
          described_class.extract_disk_info_from_df(invalid_df_output)
        }.to raise_error(RuntimeError).with_message("BUG: df data parse failed")
      end
    end
  end
end
