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

  describe "#boot_disk" do
    it "can download an image before converting it" do
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/")

      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/opt/ubuntu-jammy.qcow2.tmp")
      end.and_yield

      boot_raw = "/var/storage/test/boot.raw"

      expect(vs).to receive(:r).with("curl -L10 -o /opt/ubuntu-jammy.qcow2.tmp https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img")
      expect(vs).to receive(:r).with("truncate -s +10G #{boot_raw}")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /opt/ubuntu-jammy.qcow2 #{boot_raw}")
      expect(vs).to receive(:r).with(/setfacl.*boot.raw/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create/)
      expect(vs).to receive(:r).with(/.*rpc.py.*vhost_create_blk_controller/)

      expect(FileUtils).to receive(:mv).with("/opt/ubuntu-jammy.qcow2.tmp", "/opt/ubuntu-jammy.qcow2")
      expect(FileUtils).to receive(:chown).with("test", "test", boot_raw)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", boot_raw)
      expect(FileUtils).to receive(:ln_s).with("/var/storage/vhost/test", "/var/storage/test/vhost.sock")
      expect(vs).to receive(:r).with(/setfacl.*vhost.sock/)
      vs.storage("ubuntu-jammy")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/opt/almalinux-9.1.qcow2").and_return(true)
      vs.download_boot_image("almalinux-9.1")
    end
  end
end
