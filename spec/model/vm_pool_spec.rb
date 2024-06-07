# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmPool do
  let(:pool) {
    described_class.create_with_id(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location: "loc",
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
    let(:prj) {
      Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
    }
    let(:vm) {
      vm = create_vm(pool_id: pool.id, display_state: "running")
      vm.associate_with_project(prj)
      vm
    }

    it "returns the vm if there is one in running state" do
      locking_vms = class_double(Vm)
      expect(pool).to receive(:vms_dataset).and_return(locking_vms).at_least(:once)
      expect(locking_vms).to receive_message_chain(:for_update, :all).and_return([])  # rubocop:disable RSpec/MessageChain
      vms_dataset = [vm]
      expect(pool).to receive_message_chain(:vms_dataset, :left_join, :where, :select).and_return(vm.id) # rubocop:disable RSpec/MessageChain
      expect(Vm).to receive(:where).and_return(vms_dataset) # rubocop:disable RSpec/MessageChain
      expect(pool.pick_vm.id).to eq(vm.id)
    end
  end
end
