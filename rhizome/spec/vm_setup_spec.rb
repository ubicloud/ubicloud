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
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/opt/ubuntu-jammy.qcow2.tmp")
      end.and_yield

      expect(vs).to receive(:r).with("curl -L10 -o /opt/ubuntu-jammy.qcow2.tmp https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img")
      expect(vs).to receive(:r).with("truncate -s +10G /vm/test/boot.raw")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /opt/ubuntu-jammy.qcow2 /vm/test/boot.raw")

      expect(FileUtils).to receive(:mv).with("/opt/ubuntu-jammy.qcow2.tmp", "/opt/ubuntu-jammy.qcow2")
      expect(FileUtils).to receive(:chown).with("test", "test", "/vm/test/boot.raw")
      vs.boot_disk("ubuntu-jammy")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/opt/almalinux-9.1.qcow2").and_return(true)
      expect(vs).to receive(:r).with("truncate -s +10G /vm/test/boot.raw")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /opt/almalinux-9.1.qcow2 /vm/test/boot.raw")
      expect(FileUtils).to receive(:chown).with("test", "test", "/vm/test/boot.raw")
      vs.boot_disk("almalinux-9.1")
    end
  end
end
