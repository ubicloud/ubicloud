# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe StorageDevice do
  subject(:storage_device) { described_class.create_with_id(vm_host: vmh, name: "DEFAULT", available_storage_gib: 100, total_storage_gib: 200) }

  let(:sshable) { instance_double(Sshable) }
  let(:vmh) { Prog::Vm::HostNexus.assemble("::1").subject }
  let(:lsblk_output) { <<EOS }
{
  "blockdevices": [
    {
      "name": "nvme0n1",
      "serial": "SERIAL2",
      "mountpoints": [],
      "children": [
        {
          "name": "nvme0n1p1",
          "mountpoints": ["/mnt/data", "/"],
          "children": []
        }
      ]
    },
    {
      "name": "nvme1n1",
      "serial": "SERIAL1",
      "mountpoints": ["/var/storage/devices/test_device"],
      "children": []
    },
    {
      "name": "nvme2n1",
      "serial": "SERIAL4",
      "mountpoints": [],
      "children": [
        {
          "name": "nvme2n1p1",
          "mountpoints": ["/mnt/data", "/"],
          "children": []
        }
      ]
    }
  ]
}
EOS

  before do
    allow(vmh).to receive(:sshable).and_return(sshable)
  end

  describe "#populate_blk_dev_serial_number" do
    context "when blk_dev_serial_number has value" do
      it "do not try to populate again" do
        sd = described_class.create_with_id(vm_host_id: vmh.id, name: "DEFAULT", blk_dev_serial_number: ["SERIAL2", "SERIAL4"], available_storage_gib: 50, total_storage_gib: 100)
        expect(sshable).not_to receive(:cmd)
        expect(sd.blk_dev_serial_number).to eq(["SERIAL2", "SERIAL4"])
      end
    end

    context "when blk_dev_serial_number is nil" do
      it "populates the block device serial number" do
        expect(sshable).to receive(:cmd).with("lsblk -Jno NAME,MOUNTPOINTS,SERIAL").and_return(lsblk_output)
        expect(storage_device.populate_blk_dev_serial_number).to eq(["SERIAL2", "SERIAL4"])
      end
    end

    it "picks correct serial number for custom storage device name" do
      sd = described_class.create_with_id(vm_host: vmh, name: "test_device", available_storage_gib: 75, total_storage_gib: 150)
      expect(sshable).to receive(:cmd).with("lsblk -Jno NAME,MOUNTPOINTS,SERIAL").and_return(lsblk_output)
      expect(sd.populate_blk_dev_serial_number).to eq(["SERIAL1"])
    end

    context "when ssh cmd fails" do
      it "raises an error" do
        expect(sshable).to receive(:cmd).with("lsblk -Jno NAME,MOUNTPOINTS,SERIAL").and_return("Permission denied")
        expect { storage_device.populate_blk_dev_serial_number }.to raise_error(JSON::ParserError, "unexpected token at 'Permission denied'")
      end
    end

    context "when ssh cmd result does not contain blockdevices" do
      it "raises an error" do
        expect(sshable).to receive(:cmd).with("lsblk -Jno NAME,MOUNTPOINTS,SERIAL").and_return("{}")
        expect { storage_device.populate_blk_dev_serial_number }.to raise_error(RuntimeError, "Expected blockdevices in lsblk output")
      end
    end

    context "when ssh cmd result does not contain serial number" do
      it "raises an error" do
        expect(sshable).to receive(:cmd).with("lsblk -Jno NAME,MOUNTPOINTS,SERIAL").and_return(<<EOS)
{
  "blockdevices": [
    {
      "name": "nvme0n1",
      "mountpoints": [],
      "children": [
        {
          "name": "nvme0n1p1",
          "mountpoints": ["/mnt/data", "/"],
          "children": []
        }
      ]
    }
  ]
}
EOS
        expect { storage_device.populate_blk_dev_serial_number }.to raise_error(RuntimeError, /Expected non-empty serial number in lsblk command/)
      end
    end
  end
end
