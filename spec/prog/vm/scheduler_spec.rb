# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::Scheduler do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create_with_id(described_class::STRAND_ID, prog: "Vm::Scheduler", label: "wait") }
  let(:project) { Project.create(name: "default") }
  let(:storage_volumes) { [{"size_gib" => 11, "use_bdev_ubi" => false, "boot" => true, "vring_workers" => 1}] }

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

      expect { nx.wait }.to nap(0.2)
      expect(vms.map { it.reload.vm_host_id }).to eq([vmh.id, vmh.id])
      expect(vms.map { it.strand.schedule }).to all(be < Time.now)
    end

    it "marks the vms without capacity as waiting for capacity once" do
      vm = create_waiting_vm

      expect { nx.wait }.to nap(0.2)
      expect { nx.wait }.to nap(0.2)
      expect(vm.reload.vm_host_id).to be_nil
      expect(Semaphore.where(strand_id: vm.id, name: "waiting_for_capacity").count).to eq(1)
    end

    it "spills the runners without capacity" do
      vm = create_waiting_vm
      vm.update(created_at: Time.now - 60)
      runner = create_runner(vm)

      expect { nx.wait }.to nap(0.2)
      expect(runner.spill_over_set?).to be(true)
    end

    it "skips the vms of spilled runners" do
      create_host
      create_runner(nil).incr_spill_over
      spilled = create_waiting_vm
      create_runner(spilled).incr_spill_over
      vm = create_waiting_vm

      expect { nx.wait }.to nap(0.2)
      expect(spilled.reload.vm_host_id).to be_nil
      expect(vm.reload.vm_host_id).not_to be_nil
    end

    context "with the round log" do
      before { allow(Clog).to receive(:emit).and_call_original }

      it "logs the counts and the time of each phase of a round" do
        create_host
        create_waiting_vm
        round = {waiting: 1, tried: 1, allocated: 1, unplaced: 0, milliseconds: hash_including(:queue, :lock, :allocate, :finish)}
        expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(round)}).and_call_original

        expect { nx.wait }.to nap(0.2)
      end
    end

    context "with the bulk commit" do
      before do
        allow(Config).to receive(:central_vm_scheduler_bulk_commit).and_return(true)
        allow(Clog).to receive(:emit).and_call_original
      end

      it "logs the time of the bulk write and the one by one commits of a round" do
        create_slice_host
        create_waiting_vm
        milliseconds = hash_including(:queue, :lock, :load, :request, :candidates, :score, :bulk_plan, :bulk_write, :one_by_one, :finish)
        expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(allocated: 1, milliseconds:)}).and_call_original

        expect { nx.wait }.to nap(0.2)
      end

      def create_slice_host(cidr: "1.1.1.0/30", net6: "fd10:9b0b:6b4b:8fbb::/64", backend: true, **)
        vmh = create_host(accepts_slices: true, net6:, **)
        16.times { VmHostCpu.create(vm_host_id: vmh.id, cpu_number: it, io: it < 2, numa_node: it / 8) }
        create_vhost_block_backend(vm_host_id: vmh.id) if backend
        Address.create(cidr:, routed_to_host_id: vmh.id).populate_ipv4_addresses
        vmh
      end

      def after_plan
        expect(Scheduling::BulkCommit).to receive(:new).and_wrap_original do |original|
          original.call.tap do |bulk_commit|
            expect(bulk_commit).to receive(:plan).at_least(:once).and_wrap_original { |plan, *args| plan.call(*args).tap { yield } }
          end
        end
      end

      def allocation_rows(vms, hosts)
        {
          vms: vms.map do |vm|
            vm.reload
            slice = vm.vm_host_slice
            [
              vm.vm_host_id, vm.family, !vm.allocated_at.nil?, !vm.ephemeral_net6.nil?, !vm.local_vetho_ip.nil?,
              !vm.assigned_vm_address.nil?, vm.sshable&.host == (vm.ip4_string || vm.ip6_string),
              slice.values.slice(:name, :family, :cores, :total_cpu_percent, :used_cpu_percent, :total_memory_gib, :used_memory_gib, :enabled, :is_shared, :vm_host_id),
              slice.cpus.map(&:cpu_number).sort, slice.strand.label,
              vm.vm_storage_volumes.map { it.values.slice(:disk_index, :storage_device_id, :boot_image_id, :vhost_block_backend_id, :vring_workers, :use_bdev_ubi, :spdk_installation_id) },
            ]
          end,
          hosts: hosts.map { it.reload.values.slice(:used_cores, :used_hugepages_1g) },
          devices: StorageDevice.order(:id).select_map([:id, :available_storage_gib]),
        }
      end

      it "writes the same rows as committing the vms one by one" do
        hosts = [create_slice_host, create_slice_host(cidr: "1.1.2.0/30", net6: "fd10:9b0b:6b4b:8fbc::/64", used_cores: 3, used_hugepages_1g: 16)]
        create_vm(vm_host_id: hosts[0].id, project_id: project.id, name: "existing-vm", local_vetho_ip: "169.254.0.0/32")
        vms = [2, 4, 2].map { create_waiting_vm(vcpus: it) }
        vms[0].update(ip4_enabled: true)
        vms[0..1].each { Sshable.create_with_id(it, host: "temp_#{it.id}") }
        expect(Scheduling::Allocator::Allocation).to receive(:random_score).and_return(0).at_least(:once)

        one_by_one = nil
        DB.transaction(savepoint: true, rollback: :always) do
          expect(Config).to receive(:central_vm_scheduler_bulk_commit).and_return(false)
          expect { nx.wait }.to nap(0.2)
          one_by_one = allocation_rows(vms, hosts)
        end

        expect { described_class.new(st).wait }.to nap(0.2)
        expect(allocation_rows(vms, hosts)).to eq(one_by_one)
        expect(vms.map { it.vm_host_slice.vm_host_id }).to all(be_truthy)
      end

      it "commits the vms it cannot plan one by one after the bulk write" do
        vmh = create_slice_host(backend: false)
        vm = create_waiting_vm

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.vm_host_id).to eq(vmh.id)
        expect(vm.vm_storage_volumes.first.spdk_installation_id).not_to be_nil
      end

      it "commits the planned vms one by one if the bulk write fails" do
        vmh = create_slice_host
        vm = create_waiting_vm
        taken = create_vm_host_slice(vm_host_id: vmh.id)
        after_plan { VmHostCpu.where(vm_host_id: vmh.id, cpu_number: [2, 3]).update(vm_host_slice_id: taken.id) }
        expect(Clog).to receive(:emit).with("central vm scheduler bulk commit failed", hash_including(central_vm_scheduler_bulk_failure: {vms: 1})).and_call_original

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.vm_host_id).to eq(vmh.id)
        expect(vm.vm_host_slice.cpus.map(&:cpu_number)).to eq([4, 5])
      end

      it "uses one capacity state per host in a round, although other processes free capacity during the round" do
        vmh = create_slice_host(used_cores: 4)
        first, large, last = Array.new(3) { create_waiting_vm }
        large.update(vcpus: 8, memory_gib: 32)
        after_plan { VmHost.where(id: vmh.id).update(used_cores: 0) }
        expect(Clog).not_to receive(:emit).with("central vm scheduler failed to allocate vm", anything)

        expect { nx.wait }.to nap(0.2)
        expect([first, large, last].map { it.reload.vm_host_id }).to eq([vmh.id, nil, vmh.id])
      end

      it "plans no two vms on the last ipv4 address of a host" do
        fuller = create_slice_host(cidr: "1.1.1.1/32", used_cores: 3)
        other = create_slice_host(cidr: "1.1.2.0/30", net6: "fd10:9b0b:6b4b:8fbc::/64")
        vms = Array.new(2) { create_waiting_vm }
        vms.each { it.update(ip4_enabled: true) }

        expect { nx.wait }.to nap(0.2)
        expect(vms.map { it.reload.vm_host_id }).to contain_exactly(fuller.id, other.id)
      end

      it "sets up read only image volumes, data volumes and volumes from machine images" do
        vmh = create_slice_host
        vm = create_waiting_vm
        volumes = [
          {"size_gib" => 11, "boot" => true, "vring_workers" => 1, "machine_image_version_id" => MachineImageVersion.generate_uuid},
          {"size_gib" => 0, "boot" => false, "read_only" => true, "image" => "ubuntu-jammy", "vring_workers" => 1},
          {"size_gib" => 5, "boot" => false, "vring_workers" => 1},
        ]
        vm.vm_storage_volumes_dataset.destroy
        vm.create_storage_volumes(volumes.map { it.except("machine_image_version_id").transform_keys(&:to_sym) })
        vm.strand.update(stack: [{"storage_volumes" => volumes}])

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.vm_storage_volumes.sort_by(&:disk_index).map(&:boot_image_id)).to eq([nil, vmh.boot_images.first.id, nil])
      end

      it "marks the vms without capacity" do
        vm = create_waiting_vm

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.waiting_for_capacity_set?).to be(true)
      end

      it "adds the planned usage only to the request classes that may use the host" do
        create_slice_host(used_cores: 6, used_hugepages_1g: 40)
        other = create_slice_host(cidr: "1.1.2.0/30", net6: "fd10:9b0b:6b4b:8fbc::/64")
        large, small = Array.new(2) { create_waiting_vm }
        large.update(vcpus: 8, memory_gib: 32)

        expect { nx.wait }.to nap(0.2)
        expect(large.reload.vm_host_id).to eq(other.id)
        expect(small.reload.vm_host_id).not_to eq(other.id)
      end

      context "with fixed random numbers" do
        before { allow(SecureRandom).to receive(:random_number).and_call_original }

        it "avoids the veth and ipv6 addresses that vms on the host use" do
          vmh = create_slice_host
          expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(4, 4, 6)
          expect(SecureRandom).to receive(:random_number).with(VmHost::APIPA_LEN).and_return(5)
          used_net6 = vmh.ip6_random_vm_network.to_s
          create_vm(vm_host_id: vmh.id, project_id: project.id, name: "existing-vm", ephemeral_net6: used_net6, local_vetho_ip: VmHost::APIPA_RANGE.nth(10).to_s + "/32")
          vm = create_waiting_vm

          expect { nx.wait }.to nap(0.2)
          expect(vm.reload.ephemeral_net6.to_s).not_to eq(used_net6)
          expect(vm.local_vetho_ip.network.to_s).to eq(VmHost::APIPA_RANGE.nth(12).to_s)
        end
      end

      it "logs a vm whose host lost its last ipv4 address after it chose the host" do
        vmh = create_slice_host(cidr: "1.1.1.1/32")
        vm = create_waiting_vm
        vm.update(ip4_enabled: true)
        expect(Scheduling::BulkCommit).to receive(:new).and_wrap_original do |original|
          original.call.tap do |bulk_commit|
            expect(bulk_commit).to receive(:plannable?).and_wrap_original do |plannable, *args|
              AssignedVmAddress.create(dst_vm_id: create_vm(project_id: project.id, name: "taker").id, ip: "1.1.1.1/32", address_id: Address.first(routed_to_host_id: vmh.id).id)
              plannable.call(*args)
            end
          end
        end
        expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vm.ubid})).and_call_original

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.vm_host_id).to be_nil
      end

      it "logs a vm it fails to plan" do
        vmh = create_slice_host
        VmHostCpu.where(vm_host_id: vmh.id).update(io: true)
        vm = create_waiting_vm
        expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vm.ubid})).and_call_original

        expect { nx.wait }.to nap(0.2)
        expect(vm.reload.vm_host_id).to be_nil
      end
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

        expect { nx.wait }.to nap(0.2)
        expect(st.stack.first["reservations"]).to eq({vmh.id => large.id})

        small = create_waiting_vm
        expect { described_class.new(st).wait }.to nap(0.2)
        expect(small.reload.vm_host_id).to be_nil

        vmh.update(used_cores: 0)
        expect { described_class.new(st).wait }.to nap(0.2)
        expect(large.reload.vm_host_id).to eq(vmh.id)
        expect(st.stack.first["reservations"]).to eq({})
      end

      it "tries the vms that hold reservations first in every round" do
        holder = create_waiting_vm(vcpus: 16)
        holder.incr_waiting_for_capacity
        st.update(stack: [{"reservations" => {vmh.id => holder.id}}])
        vmh.update(used_cores: 0)

        expect { nx.wait }.to nap(0.2)
        expect(holder.reload.vm_host_id).to eq(vmh.id)
        expect(st.stack.first["reservations"]).to eq({})
      end

      it "tries a holder although its class is remembered full" do
        holder = create_waiting_vm(vcpus: 16)
        expect { nx.wait }.to nap(0.2)
        expect(st.stack.first["reservations"]).to eq({vmh.id => holder.id})
        expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 1, remembered: 1)}).and_call_original

        expect { described_class.new(st).wait }.to nap(0.2)
      end

      it "keeps the reservation while its host lacks memory for the holder" do
        holder = create_waiting_vm(vcpus: 16)
        st.update(stack: [{"reservations" => {vmh.id => holder.id}}])
        vmh.update(used_cores: 0, used_hugepages_1g: 150)

        expect { nx.wait }.to nap(0.2)
        expect(st.stack.first["reservations"]).to eq({vmh.id => holder.id})
      end

      it "releases the reservation of a holder that does not fit on its drained host" do
        holder = create_waiting_vm(vcpus: 16)
        holder.update(boot_image: "other-image")
        st.update(stack: [{"reservations" => {vmh.id => holder.id}}])
        vmh.update(used_cores: 0)
        expect(Clog).to receive(:emit).with("central vm scheduler released reservation", {central_vm_scheduler_release: {vm: holder.ubid, vm_host: vmh.ubid, reason: "unfitting"}}).and_call_original

        expect { nx.wait }.to nap(0.2)
        expect(holder.reload.vm_host_id).to be_nil
      end

      it "releases the reservation of a host that no longer exists" do
        holder = create_waiting_vm(vcpus: 16)
        gone_host_id = VmHost.generate_uuid
        st.update(stack: [{"reservations" => {gone_host_id => holder.id}}])
        expect(Clog).to receive(:emit).with("central vm scheduler released reservation", {central_vm_scheduler_release: {vm: holder.ubid, vm_host: UBID.to_ubid(gone_host_id), reason: "host gone"}}).and_call_original

        expect { nx.wait }.to nap(0.2)
        expect(st.stack.first["reservations"]).to eq({vmh.id => holder.id})
      end

      it "gives the reservation of a spilled runner to the next large vm" do
        spilled = create_waiting_vm(vcpus: 16)
        spilled.update(created_at: Time.now - 60)
        runner = create_runner(spilled)
        runner.update(label: "ubicloud-standard-16")
        large = create_waiting_vm(vcpus: 16)
        st.update(stack: [{"reservations" => {vmh.id => spilled.id}}])

        expect { nx.wait }.to nap(0.2)
        expect(runner.spill_over_set?).to be(true)
        expect(st.stack.first["reservations"]).to eq({vmh.id => large.id})
      end

      it "drops the reservations of vms that no longer wait for allocation" do
        gone = create_waiting_vm(vcpus: 16)
        gone.strand.update(label: "destroy")
        st.update(stack: [{"reservations" => {vmh.id => gone.id}}])
        small = create_waiting_vm

        expect { nx.wait }.to nap(0.2)
        expect(small.reload.vm_host_id).to eq(vmh.id)
        expect(st.stack.first["reservations"]).to eq({})
      end

      it "reserves up to the reservation limit" do
        create_host(total_hugepages_1g: 200)
        create_waiting_vm(vcpus: 16)
        create_waiting_vm(vcpus: 30)
        expect(Config).to receive(:central_vm_scheduler_max_reservations).and_return(1).twice

        expect { nx.wait }.to nap(0.2)
        expect(st.stack.first["reservations"].size).to eq(1)
      end
    end

    it "reserves no host for a large vm that no host may take" do
      create_waiting_vm(vcpus: 16)

      expect { nx.wait }.to nap(0.2)
      expect(st.stack.first["reservations"]).to eq({})
    end

    it "skips the vms it allocated whose strands did not run yet" do
      vmh = create_host
      vm = create_waiting_vm

      expect { nx.wait }.to nap(0.2)
      expect(vm.reload.vm_host_id).to eq(vmh.id)
      expect { described_class.new(st).wait }.to nap(0.2)
      expect(vmh.reload.used_cores).to eq(1 + vm.reload.cores)
    end

    it "skips the vms whose strands started to run after it read the queue" do
      create_host
      vm = create_waiting_vm
      expect(nx).to receive(:waiting_queue).and_wrap_original do |original|
        queue = original.call
        vm.strand.update(lease: Time.now + 60)
        queue
      end

      expect { nx.wait }.to nap(0.2)
      expect(vm.reload.vm_host_id).to be_nil
    end

    it "skips the vms whose strands run" do
      create_host
      vm = create_waiting_vm(lease: Time.now + 60)

      expect { nx.wait }.to nap(0.2)
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

    it "places the oldest vms first" do
      create_host(used_cores: 7)
      older, newer = Array.new(2) { create_waiting_vm }
      older.incr_waiting_for_capacity

      expect { nx.wait }.to nap(0.2)
      expect(older.reload.vm_host_id).not_to be_nil
      expect(newer.reload.vm_host_id).to be_nil
    end

    it "skips the rest of a class that does not fit, and places smaller vms behind it" do
      create_host
      *large, small = Array.new(3) { create_waiting_vm }
      large.each { it.update(vcpus: 16, memory_gib: 64) }
      [*large, small].each { it.update(location_id: Location::GITHUB_RUNNERS_ID) }
      installation = create_installation
      [*large, small].each { create_runner(it, installation:) }

      expect { nx.wait }.to nap(0.2)
      expect(small.reload.vm_host_id).not_to be_nil
      expect(large.map { it.reload.waiting_for_capacity_set? }).to eq([true, true])
    end

    it "tries one vm of a class for the runners of different customers" do
      create_host(used_cores: 7)
      vms = Array.new(3) { create_waiting_vm(vcpus: 4) }
      vms.each { it.update(location_id: Location::GITHUB_RUNNERS_ID) }
      vms.each { create_runner(it) }
      expect(Clog).to receive(:emit).with("Allocator query for vm", anything).once.and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 1, unplaced: 3)}).and_call_original

      expect { nx.wait }.to nap(0.2)
    end

    it "tries the vms of a project that owns hosts apart from the others" do
      owner = Project.create(name: "owner")
      create_host(project_id: owner.id)
      other, owned = Array.new(2) { create_waiting_vm }
      owned.update(project_id: owner.id)

      expect { nx.wait }.to nap(0.2)
      expect(other.reload.vm_host_id).to be_nil
      expect(owned.reload.vm_host_id).not_to be_nil
    end

    it "skips a full class in later rounds without a try while capacity is unchanged" do
      create_host(used_cores: 7)
      vm = create_waiting_vm(vcpus: 4)
      expect(Clog).to receive(:emit).with("Allocator query for vm", anything).once.and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 1, remembered: 0)}).and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 0, unplaced: 1, remembered: 1)}).and_call_original

      expect { nx.wait }.to nap(0.2)
      expect { described_class.new(st).wait }.to nap(0.2)
      expect(vm.reload.vm_host_id).to be_nil
    end

    it "tries a full class again once capacity frees up" do
      vmh = create_host(used_cores: 7)
      vm = create_waiting_vm(vcpus: 4)

      expect { nx.wait }.to nap(0.2)
      vmh.update(used_cores: 1)
      expect { described_class.new(st).wait }.to nap(0.2)
      expect(vm.reload.vm_host_id).to eq(vmh.id)
    end

    it "tries a full class again after central_vm_scheduler_full_class_seconds" do
      create_host(used_cores: 7)
      create_waiting_vm(vcpus: 4)
      expect(Config).to receive(:central_vm_scheduler_full_class_seconds).and_return(0)
      expect(Clog).to receive(:emit).with("Allocator query for vm", anything).twice.and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 1, remembered: 0)}).twice.and_call_original

      expect { nx.wait }.to nap(0.2)
      expect { described_class.new(st).wait }.to nap(0.2)
    end

    it "stops a round after central_vm_scheduler_max_tries tries and continues in the next one" do
      create_host
      small, large = [create_waiting_vm, create_waiting_vm(vcpus: 4)]
      expect(Config).to receive(:central_vm_scheduler_max_tries).and_return(1).twice

      expect { nx.wait }.to nap(0)
      expect([small, large].map { !it.reload.vm_host_id.nil? }).to eq([true, false])
      expect { described_class.new(st).wait }.to nap(0.2)
      expect(large.reload.vm_host_id).not_to be_nil
    end

    it "places up to the batch size in a round and continues in the next one" do
      create_host
      first, second = Array.new(2) { create_waiting_vm }
      expect(Config).to receive(:central_vm_scheduler_batch_size).and_return(1).twice

      expect { nx.wait }.to nap(0)
      expect([first, second].map { !it.reload.vm_host_id.nil? }).to eq([true, false])
      expect { described_class.new(st).wait }.to nap(0.2)
      expect(second.reload.vm_host_id).not_to be_nil
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

    it "logs the vms it fails to allocate and allocates the rest" do
      create_host(accepts_slices: true)
      vms = Array.new(2) { create_waiting_vm }
      expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vms.first.ubid})).and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler failed to allocate vm", hash_including(central_vm_scheduler_failure: {vm: vms.last.ubid})).and_call_original
      expect(Clog).to receive(:emit).with("central vm scheduler round", {central_vm_scheduler_round: hash_including(tried: 2, allocated: 0)}).and_call_original

      expect { nx.wait }.to nap(0.2)
      expect(vms.map { it.reload.vm_host_id }).to eq([nil, nil])
    end
  end
end
