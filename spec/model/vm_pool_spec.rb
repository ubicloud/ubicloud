# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmPool do
  let(:pool) {
    described_class.create(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86,
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

    %w[destroy destroying].each do |semaphore|
      it "skips a VM marked #{semaphore} and selects healthy capacity" do
        retiring_vm = create_vm(pool_id: pool.id, display_state: "running")
        Strand.create_with_id(retiring_vm, prog: "Vm::Metal::Nexus", label: "wait")
        retiring_vm.public_send("incr_#{semaphore}")

        expect(pool.pick_vm).to be_nil

        healthy_vm = create_vm(pool_id: pool.id, display_state: "running")
        expect(pool.pick_vm).to eq(healthy_vm)
      end

      it "does not select a VM from a pool marked #{semaphore}" do
        vm = create_vm(pool_id: pool.id, display_state: "running")
        Strand.create_with_id(pool, prog: "Vm::VmPool", label: "wait")
        expect(pool.pick_vm).to eq(vm)

        pool.public_send("incr_#{semaphore}")

        expect(pool.pick_vm).to be_nil
      end
    end
  end
end
