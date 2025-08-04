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
    let(:prj) {
      Project.create(name: "default")
    }
    let(:vm) {
      create_vm(pool_id: pool.id, display_state: "running", project_id: prj.id)
    }

    it "returns the vm if there is one in running state" do
      locking_vms = class_double(Vm)
      expect(pool).to receive(:vms_dataset).and_return(locking_vms)
      expect(locking_vms).to receive_message_chain(:where, :exclude, :for_no_key_update, :skip_locked, :first).and_return(vm) # rubocop:disable RSpec/MessageChain
      expect(pool.pick_vm).to eq(vm)
    end
  end
end
