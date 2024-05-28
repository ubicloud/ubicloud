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

  let(:vm) { Vm.create_with_id(pool_id: pool.id, unix_user: "x", public_key: "x", name: "x", family: "standard", cores: 2, location: "x", boot_image: "x") }

  describe ".pick_vm" do
    it "returns nil if there are no vms" do
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns nil if there are no vms in running state" do
      vm.update(provisioned_at: nil)
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns nil if there are no untainted vms" do
      vm.update(provisioned_at: Time.now, tainted_at: Time.now)
      expect(pool.pick_vm("new-name")).to be_nil
    end

    it "returns the vm if there is untainted one in running state" do
      vm.update(provisioned_at: Time.now, tainted_at: nil)
      expect(pool.pick_vm("new-name").id).to eq(vm.id)
    end
  end
end
