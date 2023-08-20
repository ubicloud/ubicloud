# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmPool do
  let(:pool) {
    described_class.create_with_id(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location: "loc"
    )
  }

  describe ".pick_vm nil case" do
    it "returns nil if there are no vms" do
      expect(pool.pick_vm).to be_nil
    end

    it "returns nil if there are no vms in running state" do
      Vm.create_with_id(
        pool_id: pool.id, display_state: "creating", unix_user: "x", public_key: "x",
        name: "x", family: "x", cores: 2, location: "x", boot_image: "x"
      )
      expect(pool.pick_vm).to be_nil
    end
  end

  describe ".pick_vm" do
    let(:prj) {
      Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
    }
    let(:vm) {
      vm = Vm.create_with_id(
        pool_id: pool.id, display_state: "running", unix_user: "x", public_key: "x",
        name: "x", family: "standard", cores: 2, location: "x", boot_image: "x"
      )
      vm.associate_with_project(prj)
      vm
    }

    it "returns the vm if there is one in running state" do
      vms_dataset = [vm]
      expect(pool).to receive_message_chain(:vms_dataset, :for_update, :where).and_return(vms_dataset) # rubocop:disable RSpec/MessageChain

      ps = instance_double(PrivateSubnet)
      expect(vm).to receive(:private_subnets).and_return([ps])
      expect(ps).to receive(:dissociate_with_project).with(prj)
      expect(vm).to receive(:dissociate_with_project).with(prj).and_call_original
      expect(vm).to receive(:update).with(pool_id: nil).and_call_original
      expect(vm).to receive(:active_billing_record).and_return(instance_double(BillingRecord)).at_least(:once)
      adr = instance_double(AssignedVmAddress, active_billing_record: instance_double(BillingRecord))
      expect(vm).to receive(:assigned_vm_address).and_return(adr).at_least(:once)
      expect(vm.active_billing_record).to receive(:finalize)
      expect(adr.active_billing_record).to receive(:finalize)
      expect(pool.pick_vm.id).to eq(vm.id)
    end

    it "skips updating billing of addresses if there is no address, still returns vm" do
      vms_dataset = [vm]
      expect(pool).to receive_message_chain(:vms_dataset, :for_update, :where).and_return(vms_dataset) # rubocop:disable RSpec/MessageChain
      expect(vm).to receive(:dissociate_with_project).with(prj).and_call_original
      expect(vm).to receive(:update).with(pool_id: nil).and_call_original
      expect(vm).to receive(:active_billing_record).and_return(instance_double(BillingRecord)).at_least(:once)
      expect(vm.active_billing_record).to receive(:finalize)
      expect(pool.pick_vm.id).to eq(vm.id)
    end
  end
end
