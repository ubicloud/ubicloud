# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmStorageVolume do
  it "can render a device_path" do
    vm = Vm.new.tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    expect(described_class.new(disk_index: 7, vm: vm).device_path).to eq("/dev/disk/by-id/virtio-vm2qnyma_7")
  end
end
