# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmPool do
  let(:pool) {
    described_class.create(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86
    )
  }

  describe ".pick_vm nil case" do
    it "returns nil if there are no vms" do
      expect(pool.pick_vm).to be_nil
    end

    it "returns nil if there are no vms in running state" do
      create_vm(pool_id: pool.id, display_state: "creating")
      expect(pool.pick_vm).to be_nil
    end
  end

  describe ".pick_vm" do
    it "returns the vm if there is one in running state" do
      vm = create_vm(pool_id: pool.id, display_state: "running")
      expect(pool.pick_vm).to eq(vm)
    end
  end
end
