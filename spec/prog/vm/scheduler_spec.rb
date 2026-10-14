# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::Scheduler do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create_with_id(described_class::STRAND_ID, prog: "Vm::Scheduler", label: "wait") }
  let(:project) { Project.create(name: "default") }
  let(:storage_volumes) { [{"size_gib" => 11, "use_bdev_ubi" => false, "boot" => true}] }

  def create_host(**)
    vmh = create_vm_host(total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, **)
    BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
    StorageDevice.create(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
    SpdkInstallation.create_with_id(vmh, vm_host_id: vmh.id, version: "v1", allocation_weight: 100)
    vmh
  end

  def create_waiting_vm(vcpus: 2, **)
    vm = create_vm(project_id: project.id, name: "vm#{Vm.count}", vcpus:, memory_gib: vcpus * 4)
    vm.create_storage_volumes(storage_volumes.map { it.transform_keys(&:to_sym) })
    Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "wait_allocation", stack: [{"storage_volumes" => storage_volumes}], schedule: Time.now + 60, **)
    vm
  end

  def counter_increments
    before = DB[:scheduler_metric_counter].to_hash(:name, :value)
    yield
    after = DB[:scheduler_metric_counter].to_hash(:name, :value)
    after.to_h { |name, value| [name, value - before.fetch(name, 0)] }.reject { |_, increment| increment.zero? }
  end

  def create_installation
    customer = Project.create(name: "customer")
    customer.set_ff_spill_to_alien_runners(true)
    GithubInstallation.create(installation_id: GithubInstallation.count + 1, project_id: customer.id, name: "ubicloud", type: "Organization")
  end

  def create_runner(vm, installation: create_installation)
    runner = GithubRunner.create(installation_id: installation.id, vm_id: vm&.id, location_id: vm && Location::GITHUB_RUNNERS_ID, repository_name: "test-repo", label: "ubicloud-standard-2")
    Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait_vm")
    runner
  end

  describe "#free_provisionings" do
    it "uses the configured value" do
      expect(nx.free_provisionings).to eq(4)
    end

    it "uses the value an operator set in the frame" do
      st.update(stack: [{"free_provisionings" => 7}])
      expect(nx.free_provisionings).to eq(7)
    end
  end

  describe "#wait" do
    it "allocates the waiting vms and wakes their strands" do
      vmh = create_host
      vms = Array.new(2) { create_waiting_vm }

      expect { nx.wait }.to nap(5)
      expect(vms.map { it.reload.vm_host_id }).to eq([vmh.id, vmh.id])
      expect(vms.map { it.strand.schedule }).to all(be < Time.now)
    end

    it "counts the checks and allocations of runner vms in the scheduler metrics" do
      create_host
      runner_vm, failed_vm = Array.new(2) { create_waiting_vm }
      [runner_vm, failed_vm].each { it.update(location_id: Location::GITHUB_RUNNERS_ID) }
      create_runner(runner_vm)
      create_runner(failed_vm)
      failed_vm.update(vcpus: 30, memory_gib: 120)
      create_waiting_vm

      expect(counter_increments { expect { nx.wait }.to nap(5) }).to eq("scheduling_checks_total" => 2, "allocated_total" => 1)
    end

    it "marks the vms without capacity as waiting for capacity once" do
      vm = create_waiting_vm

      expect { nx.wait }.to nap(5)
      expect { nx.wait }.to nap(5)
      expect(vm.reload.vm_host_id).to be_nil
      expect(Semaphore.where(strand_id: vm.id, name: "waiting_for_capacity").count).to eq(1)
    end

    it "spills the runners without capacity" do
      vm = create_waiting_vm
      vm.update(created_at: Time.now - 60)
      runner = create_runner(vm)

      expect { nx.wait }.to nap(5)
      expect(runner.spill_over_set?).to be(true)
    end

    it "skips the vms of spilled runners" do
      create_host
      create_runner(nil).incr_spill_over
      spilled = create_waiting_vm
      create_runner(spilled).incr_spill_over
      vm = create_waiting_vm

      expect { nx.wait }.to nap(5)
      expect(spilled.reload.vm_host_id).to be_nil
      expect(vm.reload.vm_host_id).not_to be_nil
    end

    context "with large vms" do
      let(:vmh) { create_host(total_hugepages_1g: 200) }

      before do
        vmh
        allow(Clog).to receive(:emit).and_call_original
      end

      it "reserves the host closest to fitting a large vm without capacity, and keeps other vms off it" do
        large = create_waiting_vm(vcpus: 16)
        expect(Clog).to receive(:emit).with("central vm scheduler reserved host", {central_vm_scheduler_reservation: {vm: large.ubid, vm_host: vmh.ubid}}).and_call_original

        expect { nx.wait }.to nap(5)
        expect(st.stack.first["reservations"]).to eq({vmh.id => large.id})

        small = create_waiting_vm
        expect { described_class.new(st).wait }.to nap(5)
        expect(small.reload.vm_host_id).to be_nil

        vmh.update(used_cores: 0)
        expect { described_class.new(st).wait }.to nap(5)
        expect(large.reload.vm_host_id).to eq(vmh.id)
        expect(st.stack.first["reservations"]).to eq({})
      end

      it "gives the reservation of a spilled runner to the next large vm" do
        spilled = create_waiting_vm(vcpus: 16)
        spilled.update(created_at: Time.now - 60)
        runner = create_runner(spilled)
        runner.update(label: "ubicloud-standard-16")
        large = create_waiting_vm(vcpus: 16)
        st.update(stack: [{"reservations" => {vmh.id => spilled.id}}])

        expect { nx.wait }.to nap(5)
        expect(runner.spill_over_set?).to be(true)
        expect(st.stack.first["reservations"]).to eq({vmh.id => large.id})
      end

      it "drops the reservations of vms that no longer wait for allocation" do
        gone = create_waiting_vm(vcpus: 16)
        gone.strand.update(label: "destroy")
        st.update(stack: [{"reservations" => {vmh.id => gone.id}}])
        small = create_waiting_vm

        expect { nx.wait }.to nap(5)
        expect(small.reload.vm_host_id).to eq(vmh.id)
        expect(st.stack.first["reservations"]).to eq({})
      end

      it "reserves up to the reservation limit" do
        create_host(total_hugepages_1g: 200)
        Array.new(2) { create_waiting_vm(vcpus: 16) }
        expect(Config).to receive(:central_vm_scheduler_max_reservations).and_return(1).twice

        expect { nx.wait }.to nap(5)
        expect(st.stack.first["reservations"].size).to eq(1)
      end
    end

    it "reserves no host for a large vm that no host may take" do
      create_waiting_vm(vcpus: 16)

      expect { nx.wait }.to nap(5)
      expect(st.stack.first["reservations"]).to eq({})
    end

    it "skips the vms it allocated whose strands did not run yet" do
      vmh = create_host
      vm = create_waiting_vm

      expect { nx.wait }.to nap(5)
      expect(vm.reload.vm_host_id).to eq(vmh.id)
      expect { described_class.new(st).wait }.to nap(5)
      expect(vmh.reload.used_cores).to eq(1 + vm.reload.cores)
    end

    it "skips the vms whose strands run" do
      create_host
      vm = create_waiting_vm(lease: Time.now + 60)

      expect { nx.wait }.to nap(5)
      expect(vm.reload.vm_host_id).to be_nil
    end

    it "picks the oldest vms first, not in id order" do
      create_host
      newer, older = Array.new(2) { create_waiting_vm }.sort_by(&:id)
      older.update(created_at: Time.now - 60)
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(1)

      expect { nx.wait }.to nap(0)
      expect(older.reload.vm_host_id).not_to be_nil
      expect(newer.reload.vm_host_id).to be_nil
    end

    it "takes turns between customers" do
      create_host(total_cpus: 64, total_cores: 32, total_hugepages_1g: 200)
      *busy, other = Array.new(4) { create_waiting_vm }
      other.update(project_id: Project.create(name: "other").id)
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(2)

      expect { nx.wait }.to nap(0)
      expect([*busy, other].select { it.reload.vm_host_id }).to eq([busy.first, other])
    end

    it "takes turns between the installations of runners" do
      create_host(total_cpus: 64, total_cores: 32, total_hugepages_1g: 200)
      *busy, other = Array.new(4) { create_waiting_vm }
      installation = create_installation
      busy.each { create_runner(it, installation:) }
      create_runner(other)
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(2)

      expect { nx.wait }.to nap(0)
      expect([*busy, other].select { it.reload.vm_host_id }).to eq([busy.first, other])
    end

    it "tries the vms that did not fail to fit before the ones that did" do
      create_host
      failed = create_waiting_vm
      failed.incr_waiting_for_capacity
      fresh = create_waiting_vm
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(1)

      expect { nx.wait }.to nap(0)
      expect(fresh.reload.vm_host_id).not_to be_nil
      expect(failed.reload.vm_host_id).to be_nil
      expect(st.stack.first["retry_cursor"]).to be_nil
    end

    it "takes turns between customers over the vms that failed to fit" do
      create_host(total_cpus: 64, total_cores: 32, total_hugepages_1g: 200)
      *busy, other = Array.new(4) { create_waiting_vm }
      other.update(project_id: Project.create(name: "other").id)
      [*busy, other].each(&:incr_waiting_for_capacity)
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(2)

      expect { nx.wait }.to nap(0)
      expect([*busy, other].select { it.reload.vm_host_id }).to eq([busy.first, other])
      expect(st.stack.first["retry_cursor"]).to eq([0, other.reload.created_at.utc.iso8601(6), other.id])
    end

    it "takes turns over the vms that failed to fit with the cursor" do
      first, second = Array.new(2) { create_waiting_vm }
      [first, second].each(&:incr_waiting_for_capacity)
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(1).twice

      expect { nx.wait }.to nap(0)
      expect(st.stack.first["retry_cursor"]).to eq([0, first.reload.created_at.utc.iso8601(6), first.id])

      create_host
      expect { described_class.new(st).wait }.to nap(5)
      expect(first.reload.vm_host_id).to be_nil
      expect(second.reload.vm_host_id).not_to be_nil
      expect(st.stack.first["retry_cursor"]).to be_nil
    end

    it "logs the vms it fails to allocate and allocates the rest" do
      create_host(accepts_slices: true)
      vms = Array.new(2) { create_waiting_vm }
      expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vms.first.ubid})).and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vms.last.ubid})).and_call_original

      expect { nx.wait }.to nap(5)
      expect(vms.map { it.reload.vm_host_id }).to eq([nil, nil])
    end
  end
end
