# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmPool do
  subject(:pool) {
    described_class.create_with_id(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location: "loc",
      storage_size_gib: 86
    )
  }

  let(:vm) { create_vm(pool_id: pool.id, display_state: "creating") }

  describe ".pick_vm" do
    it "returns nil if there are no vms" do
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns nil if there are no vms in running state" do
      vm.update(display_state: "creating")
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns nil if there are no vms without user data" do
      vm.update(display_state: "running", has_customer_data: true)
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns the vm if there is a vm without user data in running state" do
      vm.update(display_state: "running", has_customer_data: false)
      expect(pool.pick_vm("new-name").id).to eq(vm.id)
    end
  end
end
