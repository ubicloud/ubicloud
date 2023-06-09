# frozen_string_literal: true

require_relative "../lib/vm_setup"

RSpec.describe VmSetup do
  subject(:vs) { described_class.new("test") }

  it "can halve an IPv6 network" do
    lower, upper = vs.subdivide_network(NetAddr.parse_net("2a01:4f9:2b:35b:7e40::/79"))
    expect(lower.to_s).to eq("2a01:4f9:2b:35b:7e40::/80")
    expect(upper.to_s).to eq("2a01:4f9:2b:35b:7e41::/80")
  end

  it "templates user YAML" do
    vps = instance_spy(VmPath)
    expect(vs).to receive(:vp).and_return(vps).at_least(:once)
    vs.write_user_data("some_user", "some_ssh_key")
    expect(vps).to have_received(:write_user_data) {
      expect(_1).to match(/some_user/)
      expect(_1).to match(/some_ssh_key/)
    }
  end

  describe "#setup_volume" do
    it "can setup a storage volume" do
      disk_file = "/var/storage/test/disk_0.raw"
      device_id = "some_device_id"

      expect(vs).to receive(:setup_disk_file).and_return(disk_file)
      expect(vs).to receive(:r).with(/setfacl.*#{disk_file}/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create/)
      expect(vs).to receive(:r).with(/.*rpc.py.*vhost_create_blk_controller test_0 #{device_id}/)
      expect(FileUtils).to receive(:chown).with("test", "test", disk_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", disk_file)
      expect(FileUtils).to receive(:ln_s).with("/var/storage/vhost/test_0", "/var/storage/test/vhost_0.sock")
      expect(vs).to receive(:r).with(/setfacl.*vhost_0.sock/)

      expect(
        vs.setup_volume({"boot" => true, "size_gib" => 5, "device_id" => device_id}, 0, "ubuntu-jammy")
      ).to eq("/var/storage/test/vhost_0.sock")
    end
  end

  describe "#setup_disk_file" do
    it "can setup a boot disk" do
      boot_image = "ubuntu-jammy"
      image_path = "/opt/#{boot_image}.qcow2"
      disk_file = "/var/storage/test/disk_0.raw"
      expect(vs).to receive(:download_boot_image).and_return image_path
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw #{image_path} #{disk_file}")
      expect(File).to receive(:size).with(disk_file).and_return(2 * 2**30)
      expect(vs).to receive(:r).with("truncate -s 5G #{disk_file}")
      expect(
        vs.setup_disk_file({"boot" => true, "size_gib" => 5, "device_id" => "disk0"}, 0, boot_image)
      ).to eq(disk_file)
    end

    it "fails if requested size is too small" do
      boot_image = "ubuntu-jammy"
      image_path = "/opt/#{boot_image}.qcow2"
      disk_file = "/var/storage/test/disk_0.raw"
      expect(vs).to receive(:download_boot_image).and_return image_path
      expect(vs).to receive(:r)
      expect(File).to receive(:size).with(disk_file).and_return(5 * 2**30)
      expect {
        vs.setup_disk_file({"boot" => true, "size_gib" => 4, "device_id" => "disk0"}, 0, boot_image)
      }.to raise_error RuntimeError, "Image size greater than requested disk size"
    end

    it "can setup a non-boot disk" do
      disk_file = "/var/storage/test/disk_0.raw"
      expect(FileUtils).to receive(:touch).with(disk_file)
      expect(vs).to receive(:r).with("truncate -s 5G #{disk_file}")
      expect(
        vs.setup_disk_file({"boot" => false, "size_gib" => 5, "device_id" => "disk0"}, 0, "boot_image")
      ).to eq(disk_file)
    end
  end

  describe "#download_boot_image" do
    it "can download an image" do
      expect(File).to receive(:exist?).with("/opt/ubuntu-jammy.qcow2").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/opt/ubuntu-jammy.qcow2.tmp")
      end.and_yield
      expect(FileUtils).to receive(:mv).with("/opt/ubuntu-jammy.qcow2.tmp", "/opt/ubuntu-jammy.qcow2")
      expect(vs).to receive(:r).with("curl -L10 -o /opt/ubuntu-jammy.qcow2.tmp https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img")

      vs.download_boot_image("ubuntu-jammy")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/opt/almalinux-9.1.qcow2").and_return(true)
      vs.download_boot_image("almalinux-9.1")
    end
  end
end
