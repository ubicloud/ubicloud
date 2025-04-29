# frozen_string_literal: true

require_relative "../model/spec_helper"
require "netaddr"

Al = Scheduling::Allocator
TestAllocation = Struct.new(:score, :is_valid)
TestResourceAllocation = Struct.new(:utilization, :is_valid)
RSpec.describe Al do
  let(:vm) {
    Vm.new(family: "standard", vcpus: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, memory_gib: 8, name: "dummy-vm", arch: "x64", location_id: Location::HETZNER_FSN1_ID, ip4_enabled: "true", created_at: Time.now, unix_user: "", public_key: "", boot_image: "ubuntu-jammy").tap {
      it.id = "2464de61-7501-8374-9ab0-416caebe31da"
    }
  }

  # Creates a Request object with the given parameters
  #
  def create_req(vm, storage_volumes, target_host_utilization: 0.55, distinct_storage_devices: false, gpu_count: 0, allocation_state_filter: ["accepting"], host_filter: [], host_exclusion_filter: [], location_filter: [], location_preference: [], use_slices: true, require_shared_slice: false, diagnostics: false, family_filter: [])
    Al::Request.new(
      vm.id,
      vm.vcpus,
      vm.memory_gib,
      storage_volumes.map { it["size_gib"] }.sum,
      storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
      vm.boot_image,
      distinct_storage_devices,
      gpu_count,
      true,
      target_host_utilization,
      vm.arch,
      allocation_state_filter,
      host_filter,
      host_exclusion_filter,
      location_filter,
      location_preference,
      vm.family,
      vm.cpu_percent_limit,
      use_slices,
      require_shared_slice,
      diagnostics,
      family_filter
    )
  end

  describe "allocation_request" do
    let(:storage_volumes) {
      [{
        "use_bdev_ubi" => false,
        "skip_sync" => true,
        "size_gib" => 11,
        "boot" => true
      }, {
        "use_bdev_ubi" => true,
        "skip_sync" => false,
        "size_gib" => 22,
        "boot" => false
      }]
    }

    let(:project) {
      instance_double(Project)
    }

    before do
      allow(project).to receive_messages(
        get_ff_allocator_diagnostics: nil
      )
      allow(vm).to receive_messages(project: project)
    end

    it "fails if no valid allocation is found" do
      expect(Al::Allocation).to receive(:best_allocation).and_return(nil)
      expect { described_class.allocate(vm, storage_volumes) }.to raise_error RuntimeError, "Vm[\"#{vm.ubid}\"] no space left on any eligible host"
    end

    it "persists valid allocation" do
      al = instance_double(Al::Allocation)
      expect(Al::Allocation).to receive(:best_allocation)
        .with(Al::Request.new(
          "2464de61-7501-8374-9ab0-416caebe31da", 2, 8, 33,
          [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
            [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
          "ubuntu-jammy", false, 0, true, Config.allocator_target_host_utilization, "x64", ["accepting"], [], [], [], [],
          "standard", 200, true, false, false, []
        )).and_return(al)
      expect(al).to receive(:update)

      described_class.allocate(vm, storage_volumes)
    end

    it "forces vm host without any filter" do
      al = instance_double(Al::Allocation)
      expect(Al::Allocation).to receive(:best_allocation)
        .with(Al::Request.new(
          "2464de61-7501-8374-9ab0-416caebe31da", 2, 8, 33,
          [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
            [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
          "ubuntu-jammy", false, 0, true, Config.allocator_target_host_utilization, "x64", [], ["eb1c0420-1e9b-8371-a594-f93f73ed5f28"], [], [], [],
          "standard", 200, true, false, false, []
        )).and_return(al)
      expect(al).to receive(:update)

      described_class.allocate(vm, storage_volumes, host_filter: ["vm123"], family_filter: ["performance"], force_host_id: "eb1c0420-1e9b-8371-a594-f93f73ed5f28")
    end

    it "handles non-existing family" do
      vm.family = "non-existing-family"
      expect { described_class.allocate(vm, storage_volumes) }.to raise_error RuntimeError, /no space left on any eligible host/
    end
  end

  describe "candidate_selection" do
    let(:req) {
      Al::Request.new(
        "2464de61-7501-8374-9ab0-416caebe31da", 4, 8, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, 0, true, 0.65, "x64", ["accepting"], [], [], [], [],
        "standard", 400, true, false, false, []
      )
    }

    it "prints diagnostics if flagged" do
      expect(req).to receive(:diagnostics).and_return(true)
      expect(Clog).to receive(:emit).with("Allocator query for vm") do |&blk|
        expect(blk.call[:allocator_query].keys).to eq([:vm_id, :sql])
      end
      Al::Allocation.best_allocation(req)
    end

    it "selects the best allocation candidate" do
      candidates = [[0.1, false], [5, true], [0.9, true], [99, true]]
      candidates.each { expect(Al::Allocation).to receive(:new).once.ordered.with(it, req).and_return TestAllocation.new(it[0], it[1]) }
      expect(Al::Allocation).to receive(:candidate_hosts).with(req).and_return(candidates)
      expect(Al::Allocation).to receive(:random_score).and_return(0).at_least(:once)

      expect(Al::Allocation.best_allocation(req)).to eq(TestAllocation.new(0.9, true))
    end

    it "disqualifies invalid candidates" do
      vmh1 = create_vm_host(allocation_state: "accepting", arch: "x64", location_id: Location::HETZNER_FSN1_ID, total_cores: 7, used_cores: 6, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(allocation_state: "draining", arch: "x64", location_id: Location::HETZNER_FSN1_ID, total_cores: 8, used_cores: 1, total_hugepages_1g: 8, used_hugepages_1g: 2)
      vmh3 = create_vm_host(allocation_state: "accepting", arch: "arm64", location_id: Location::HETZNER_FSN1_ID, total_cores: 8, used_cores: 0, total_hugepages_1g: 8, used_hugepages_1g: 0)
      vmh4 = create_vm_host(allocation_state: "accepting", arch: "x64", location_id: Location::HETZNER_FSN1_ID, total_cores: 8, used_cores: 6, total_hugepages_1g: 8, used_hugepages_1g: 5)
      vmh5 = create_vm_host(allocation_state: "accepting", arch: "x64", location_id: "6b9ef786-b842-8420-8c65-c25e3d4bdf3d", total_cores: 8, used_cores: 6, total_hugepages_1g: 80, used_hugepages_1g: 5)

      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh3.id, name: "stor1", available_storage_gib: 20, total_storage_gib: 30)
      StorageDevice.create_with_id(vm_host_id: vmh3.id, name: "stor2", available_storage_gib: 20, total_storage_gib: 30)
      StorageDevice.create_with_id(vm_host_id: vmh4.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh5.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100, enabled: false)

      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      Address.create_with_id(cidr: "3.1.1.0/30", routed_to_host_id: vmh3.id)
      Address.create_with_id(cidr: "4.1.1.0/30", routed_to_host_id: vmh4.id)
      Address.create_with_id(cidr: "5.1.1.0/30", routed_to_host_id: vmh5.id)

      expect(Al::Allocation.candidate_hosts(req)).to eq([])
    end

    it "retrieves correct values" do
      vmh = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 3, total_hugepages_1g: 10, used_hugepages_1g: 2)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      sd1 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 123, total_storage_gib: 345)
      sd2 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 12, total_storage_gib: 99)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)

      expect(Al::Allocation.candidate_hosts(req))
        .to eq([{location_id: vmh.location_id,
                 num_storage_devices: 2,
                 storage_devices: [{"available_storage_gib" => sd2.available_storage_gib, "id" => sd2.id, "total_storage_gib" => sd2.total_storage_gib},
                   {"available_storage_gib" => sd1.available_storage_gib, "id" => sd1.id, "total_storage_gib" => sd1.total_storage_gib}],
                 total_cpus: vmh.total_cpus,
                 total_cores: vmh.total_cores,
                 total_hugepages_1g: vmh.total_hugepages_1g,
                 total_storage_gib: sd1.total_storage_gib + sd2.total_storage_gib,
                 available_storage_gib: sd1.available_storage_gib + sd2.available_storage_gib,
                 used_cores: vmh.used_cores,
                 used_hugepages_1g: vmh.used_hugepages_1g,
                 vm_host_id: vmh.id,
                 total_ipv4: 4,
                 num_gpus: 0,
                 available_gpus: 0,
                 available_iommu_groups: nil,
                 used_ipv4: 1,
                 vm_provisioning_count: 0,
                 accepts_slices: false,
                 family: "standard"}])
    end

    it "retrieves provisioning count" do
      vmh = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 3, total_hugepages_1g: 10, used_hugepages_1g: 2)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      sd1 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 123, total_storage_gib: 345)
      create_vm(vm_host_id: vmh.id, location_id: vmh.location_id, boot_image: "", display_state: "creating")
      create_vm(vm_host_id: vmh.id, location_id: vmh.location_id, boot_image: "ubuntu-jammy", display_state: "creating")
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)

      expect(Al::Allocation.candidate_hosts(req))
        .to eq([{location_id: vmh.location_id,
                 num_storage_devices: 1,
                 storage_devices: [{"available_storage_gib" => sd1.available_storage_gib, "id" => sd1.id, "total_storage_gib" => sd1.total_storage_gib}],
                 total_cpus: vmh.total_cpus,
                 total_cores: vmh.total_cores,
                 total_hugepages_1g: vmh.total_hugepages_1g,
                 total_storage_gib: sd1.total_storage_gib,
                 available_storage_gib: sd1.available_storage_gib,
                 used_cores: vmh.used_cores,
                 used_hugepages_1g: vmh.used_hugepages_1g,
                 vm_host_id: vmh.id,
                 total_ipv4: 4,
                 num_gpus: 0,
                 available_gpus: 0,
                 available_iommu_groups: nil,
                 used_ipv4: 1,
                 vm_provisioning_count: 2,
                 accepts_slices: false,
                 family: "standard"}])
    end

    it "applies host filter" do
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.host_filter = [vmh2.id]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
    end

    it "applies host exclusion filter" do
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.host_exclusion_filter = [vmh1.id]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
    end

    it "applies location filter" do
      vmh1 = create_vm_host(location_id: Location::HETZNER_FSN1_ID, total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(location_id: "6b9ef786-b842-8420-8c65-c25e3d4bdf3d", total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.location_filter = [Location::HETZNER_FSN1_ID]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh1.id)
    end

    it "applies family filter" do
      vmh1 = create_vm_host(family: "premium", total_cpus: 10, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(family: "standard", total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.family_filter = ["premium"]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh1.id)
    end

    it "retrieves candidates with enough storage devices" do
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor2", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.distinct_storage_devices = true
      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
    end

    it "retrieves candidates with available ipv4 addresses if ip4_enabled" do
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/32", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh1.id)
    end

    it "retrieves candidates without available ipv4 addresses if not ip4_enabled" do
      req.ip4_enabled = false
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/32", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(2)
    end

    it "retrieves candidates with gpu if gpu_count > 0" do
      vmh1 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      vmh2 = create_vm_host(total_cpus: 14, total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2)
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "02:00.0", device_class: "0300", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 9)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "03:00.0", device_class: "1234", vendor: "vd", device: "dv3", numa_node: 0, iommu_group: 11)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)

      req.gpu_count = 1
      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
      expect(cand.first[:available_iommu_groups].sort).to eq([3, 9])
    end
  end

  describe "Allocation" do
    let(:req) {
      Al::Request.new(
        "2464de61-7501-8374-9ab0-416caebe31da", 4, 16, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, 0, true, 0.65, "x64", ["accepting"], [], [], [], [],
        "standard", 400
      )
    }
    let(:vmhds) {
      {location_id: Location::HETZNER_FSN1_ID,
       num_storage_devices: 2,
       storage_devices: [{"available_storage_gib" => 10, "id" => "sd1id", "total_storage_gib" => 10},
         {"available_storage_gib" => 101, "id" => "sd2id", "total_storage_gib" => 91}],
       total_storage_gib: 111,
       available_storage_gib: 101,
       total_cpus: 16,
       total_cores: 8,
       used_cores: 3,
       total_hugepages_1g: 22,
       used_hugepages_1g: 9,
       num_gpus: 0,
       available_gpus: 0,
       vm_host_id: "15e11815-3d4f-8771-9cac-ce4cdcbda5c1",
       vm_provisioning_count: 0}
    }

    it "initializes individual resource allocations" do
      expect(Al::VmHostCpuAllocation).to receive(:new).with(:used_cores, vmhds[:total_cores], vmhds[:used_cores], req.cores_for_vcpus(vmhds[:total_cpus] / vmhds[:total_cores])).and_return(instance_double(Al::VmHostCpuAllocation, utilization: req.target_host_utilization, is_valid: true))
      expect(Al::VmHostAllocation).to receive(:new).with(:used_hugepages_1g, vmhds[:total_hugepages_1g], vmhds[:used_hugepages_1g], req.memory_gib).and_return(instance_double(Al::VmHostAllocation, utilization: req.target_host_utilization, is_valid: true))
      expect(Al::StorageAllocation).to receive(:new).with(vmhds, req).and_return(instance_double(Al::StorageAllocation, utilization: req.target_host_utilization, is_valid: true))

      allocation = Al::Allocation.new(vmhds, req)
      expect(allocation.score).to eq 0
      expect(allocation.is_valid).to be_truthy
    end

    it "is valid only if all resource allocations are valid" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, false))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))

      allocation = Al::Allocation.new(vmhds, req)
      expect(allocation.score).to eq 0
      expect(allocation.is_valid).to be_falsy
    end

    it "has score of 0 if all resources are at target utilization" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))

      expect(Al::Allocation.new(vmhds, req).score).to eq 0
    end

    it "is penalized if utilization is below target" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 0.9, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 0.9, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 0.9, true))
      expect(Al::Allocation.new(vmhds, req).score).to be > 0
    end

    it "penalizes over-utilization more than under-utilization" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_low_utilization = Al::Allocation.new(vmhds, req).score

      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 1.01, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 1.01, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 1.01, true))
      score_over_target = Al::Allocation.new(vmhds, req).score

      expect(score_over_target).to be > score_low_utilization
    end

    it "penalizes imbalance" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      score_balance = Al::Allocation.new(vmhds, req).score

      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.4, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.6, true))
      score_imbalance = Al::Allocation.new(vmhds, req).score

      expect(score_imbalance).to be > score_balance
    end

    it "penalizes concurrent provisioning for github runners" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      vmhds[:location_id] = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
      vmhds[:vm_provisioning_count] = 1
      expect(Al::Allocation.new(vmhds, req).score).to eq(0.5)
    end

    it "penalizes AX161 github runners" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      vmhds[:location_id] = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
      vmhds[:total_cores] = 32
      vmhds[:total_cpus] = 64
      expect(Al::Allocation.new(vmhds, req).score).to eq(0.5)
    end

    it "prioritize AX102 github runners for premium CPU testers" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      vmhds[:location_id] = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
      vmhds[:family] = "premium"
      expect(Al::Allocation.new(vmhds, req).score).to eq(-1)
    end

    it "respects location preferences" do
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_no_preference = Al::Allocation.new(vmhds, req).score

      req.location_preference = [Location::HETZNER_FSN1_ID]
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_preference_met = Al::Allocation.new(vmhds, req).score

      req.location_preference = ["6b9ef786-b842-8420-8c65-c25e3d4bdf3d"]
      expect(Al::VmHostCpuAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      score_preference_not_met = Al::Allocation.new(vmhds, req).score

      expect(score_no_preference).to be_within(0.0001).of(score_preference_met)
      expect(score_preference_not_met).to be > score_preference_met
    end
  end

  describe "VmHostAllocation" do
    it "is valid if requested is less than or equal to used" do
      expect(Al::VmHostAllocation.new(:used_res, 100, 50, 25).is_valid).to be_truthy
      expect(Al::VmHostAllocation.new(:used_res, 100, 50, 50).is_valid).to be_truthy
    end

    it "is invalid if requested is less than used" do
      expect(Al::VmHostAllocation.new(:used_res, 100, 50, 51).is_valid).to be_falsy
    end

    it "raises an error if used is greater than total" do
      expect { Al::VmHostAllocation.new(:used_res, 100, 101, 25) }.to raise_error RuntimeError, "resource 'used_res' uses more than is available: 101 > 100"
    end

    it "returns correct update value on update" do
      expect(Al::VmHostAllocation.new(:used_res, 100, 50, 25).get_vm_host_update).to eq({used_res: Sequel[:used_res] + 25})
    end
  end

  describe "StorageAllocation" do
    let(:req) {
      Al::Request.new(
        "2464de61-7501-8374-9ab0-416caebe31da", 4, 8, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, 0.65, "x64", ["accepting"], [], [], [], [],
        "standard", 200
      )
    }
    let(:vmhds) {
      {location_id: Location::HETZNER_FSN1_ID,
       num_storage_devices: 2,
       storage_devices: [{"available_storage_gib" => 10, "id" => "sd1id", "total_storage_gib" => 10},
         {"available_storage_gib" => 91, "id" => "sd2id", "total_storage_gib" => 101}],
       total_storage_gib: 111,
       available_storage_gib: 101,
       total_cores: 8,
       used_cores: 3,
       total_hugepages_1g: 22,
       used_hugepages_1g: 9,
       vm_host_id: "the_id"}
    }

    it "can allocate storage on the same device" do
      req.distinct_storage_devices = false
      req.storage_volumes = [[1, {"size_gib" => 12}], [0, {"size_gib" => 12}]]
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_truthy
      expect(storage_allocation.volume_to_device_map).to eq({1 => "sd2id", 0 => "sd2id"})
    end

    it "can allocate storage on distinct devices" do
      req.distinct_storage_devices = true
      req.storage_volumes = [[1, {"size_gib" => 50}], [0, {"size_gib" => 10}]]
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_truthy
      expect(storage_allocation.volume_to_device_map).to eq({1 => "sd2id", 0 => "sd1id"})
    end

    it "fails if there is not enough space available" do
      req.storage_gib = 10000
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_falsey
    end

    it "fails if distinct devices are requested but not available" do
      req.distinct_storage_devices = true
      req.storage_volumes = [[1, {"size_gib" => 1}], [0, {"size_gib" => 1}], [2, {"size_gib" => 1}]]
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_falsey
    end

    it "can calculate utilization" do
      req.storage_gib = 101
      req.storage_volumes = [[0, {"size_gib" => 91}], [1, {"size_gib" => 10}]]
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_truthy
      expect(storage_allocation.utilization).to be_within(0.0001).of(1)

      req.storage_gib = 2
      req.storage_volumes = [[0, {"size_gib" => 1}], [1, {"size_gib" => 1}]]
      storage_allocation = Al::StorageAllocation.new(vmhds, req)
      expect(storage_allocation.is_valid).to be_truthy
      expect(storage_allocation.utilization).to be_within(0.01).of(0.1)
    end
  end

  describe "update" do
    let(:vol) {
      [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => false, "boot" => false}]
    }

    before do
      vmh = create_vm_host(net6: "fd10:9b0b:6b4b:8fbb::/64", total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { it.id = vmh.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
    end

    it "updates resources" do
      vm = create_vm
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { it.available_storage_gib }
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      expect(vm.vm_storage_volumes.detect { it.disk_index == 0 }.size_gib).to eq(85)
      expect(vm.vm_storage_volumes.detect { it.disk_index == 1 }.size_gib).to eq(95)
      expect(StorageDevice[vm.vm_storage_volumes.detect { it.disk_index == 0 }.storage_device_id].name).to eq("stor2")
      expect(StorageDevice[vm.vm_storage_volumes.detect { it.disk_index == 1 }.storage_device_id].name).to eq("stor1")
      expect(used_cores + vm.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm.memory_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 180).to eq(vmh.storage_devices.sum { it.available_storage_gib })
      expect(vmh.pci_devices.map { it.vm_id }).to eq([nil, nil])
    end

    it "updates pci devices" do
      vm = create_vm
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { it.available_storage_gib }
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}], gpu_count: 1)
      vmh.reload
      expect(vm.vm_storage_volumes.detect { it.disk_index == 0 }.size_gib).to eq(85)
      expect(vm.vm_storage_volumes.detect { it.disk_index == 1 }.size_gib).to eq(95)
      expect(StorageDevice[vm.vm_storage_volumes.detect { it.disk_index == 0 }.storage_device_id].name).to eq("stor2")
      expect(StorageDevice[vm.vm_storage_volumes.detect { it.disk_index == 1 }.storage_device_id].name).to eq("stor1")
      expect(used_cores + vm.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm.memory_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 180).to eq(vmh.storage_devices.sum { it.available_storage_gib })
      expect(vmh.pci_devices.map { it.vm_id }).to eq([vm.id, vm.id])
    end

    it "allows concurrent allocations" do
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { it.available_storage_gib }
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      al2.update(vm2)
      vmh.reload
      expect(used_cores + vm1.cores + vm2.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm1.memory_gib + vm2.memory_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 10).to eq(vmh.storage_devices.sum { it.available_storage_gib })
    end

    it "fails concurrent allocations if core constraints are violated" do
      vmh = VmHost.first
      vmh.update(used_cores: vmh.used_cores + 6)
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(Sequel::CheckConstraintViolation, /core_allocation_limit/)
    end

    it "fails concurrent allocations if memory constraints are violated" do
      vmh = VmHost.first
      vmh.update(used_hugepages_1g: vmh.used_hugepages_1g + 37)
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(Sequel::CheckConstraintViolation, /hugepages_allocation_limit/)
    end

    it "fails concurrent allocations if storage constraints are violated" do
      vm1 = create_vm
      vm2 = create_vm
      vol = [{"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}]
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(Sequel::CheckConstraintViolation, /available_storage_gib_non_negative/)
    end

    it "fails concurrent allocations of gpus" do
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol, gpu_count: 1))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol, gpu_count: 1))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(RuntimeError, "concurrent GPU allocation")
    end

    it "creates volume without encryption key if storage is not encrypted" do
      vm = create_vm
      described_class.allocate(vm, vol)
      expect(StorageKeyEncryptionKey.count).to eq(0)
      expect(vm.reload.vm_storage_volumes.first.key_encryption_key_1_id).to be_nil
      expect(vm.storage_secrets.count).to eq(0)
    end

    it "creates volume with rate limits" do
      vm = create_vm
      vol = [{
        "size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => false,
        "boot" => false, "max_ios_per_sec" => 100, "max_read_mbytes_per_sec" => 200,
        "max_write_mbytes_per_sec" => 300, "rate_limit_bytes_write" => 400
      }]
      described_class.allocate(vm, vol)
      expect(vm.reload.vm_storage_volumes.first.max_ios_per_sec).to eq(100)
      expect(vm.vm_storage_volumes.first.max_read_mbytes_per_sec).to eq(200)
      expect(vm.vm_storage_volumes.first.max_write_mbytes_per_sec).to eq(300)
    end

    it "creates volume with no rate limits" do
      vm = create_vm
      described_class.allocate(vm, vol)
      expect(vm.reload.vm_storage_volumes.first.max_ios_per_sec).to be_nil
      expect(vm.vm_storage_volumes.first.max_read_mbytes_per_sec).to be_nil
      expect(vm.vm_storage_volumes.first.max_write_mbytes_per_sec).to be_nil
    end

    it "can have empty allocation state filter" do
      vmh = VmHost.first
      vmh.update(allocation_state: "draining")
      al = Al::Allocation.best_allocation(create_req(vm, vol, allocation_state_filter: []))
      expect(al).to be_truthy
    end

    it "can have empty family filter" do
      vmh = VmHost.first
      vmh.update(family: "premium")
      al = Al::Allocation.best_allocation(create_req(vm, vol, family_filter: []))
      expect(al).to be_truthy
    end

    it "creates volume with encryption key if storage is encrypted" do
      vm = create_vm
      described_class.allocate(vm, [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      expect(StorageKeyEncryptionKey.count).to eq(1)
      expect(vm.vm_storage_volumes.first.key_encryption_key_1_id).not_to be_nil
      expect(vm.storage_secrets.count).to eq(1)
    end

    it "allocates the latest active boot image for boot volumes" do
      vmh = VmHost.first
      BootImage.where(vm_host_id: vmh.id).update(activated_at: nil)
      bi = BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "20230303", activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: nil, activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "20240404", activated_at: nil, size_gib: 3)
      vm = create_vm
      described_class.allocate(vm, [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => true}])
      expect(vm.vm_storage_volumes.first.boot_image_id).to eq(bi.id)
    end

    it "fails if no active boot images are available" do
      vmh = VmHost.first
      BootImage.where(vm_host_id: vmh.id).update(activated_at: nil)
      vm = create_vm
      expect {
        described_class.allocate(vm, [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => true}])
      }.to raise_error(RuntimeError, /no space left on any eligible host/)
    end

    it "allocates the latest active image for read-only volumes" do
      vmh = VmHost.first
      BootImage.where(vm_host_id: vmh.id).update(activated_at: nil)
      bi = BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "20230303", activated_at: Time.now, size_gib: 3)
      mi = BootImage.create_with_id(vm_host_id: vmh.id, name: "ai-model-test-model", version: "20240406", activated_at: Time.now, size_gib: 3)
      BootImage.create_with_id(vm_host_id: vmh.id, name: "ai-model-test-model", version: "20240404", activated_at: Time.now, size_gib: 3)
      vm = create_vm
      described_class.allocate(vm, [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => true}, {"size_gib" => 0, "read_only" => true, "image" => "ai-model-test-model", "boot" => false, "skip_sync" => true, "encrypted" => false, "use_bdev_ubi" => false}])
      expect(vm.vm_storage_volumes.first.boot_image_id).to eq(bi.id)
      expect(vm.vm_storage_volumes.last.boot_image_id).to eq(mi.id)
    end

    it "calls update_vm" do
      vm = create_vm
      expect(Al::Allocation).to receive(:update_vm).with(VmHost.first, vm)
      described_class.allocate(vm, vol)
    end

    it "allocates the vm to a host with IPv4 address" do
      vm = create_vm
      vmh = VmHost.first
      address = Address.new(cidr: "0.0.0.0/30", routed_to_host_id: vmh.id)
      assigned_address = AssignedVmAddress.new(ip: NetAddr::IPv4Net.parse("10.0.0.1"))
      expect(vmh).to receive(:ip4_random_vm_network).and_return(["0.0.0.0", address])
      expect(vm).to receive(:ip4_enabled).and_return(true).twice
      expect(AssignedVmAddress).to receive(:create_with_id).and_return(assigned_address)
      expect(vm).to receive(:assigned_vm_address).and_return(assigned_address)
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable)).at_least(:once)
      expect(vm.sshable).to receive(:update).with(host: assigned_address.ip.network)
      Al::Allocation.update_vm(vmh, vm)
    end

    it "fails if there is no ip address available but the vm is ip4 enabled" do
      vm = create_vm
      vmh = VmHost.first
      expect(vmh).to receive(:ip4_random_vm_network).and_return([nil, nil])
      expect(vm).to receive(:ip4_enabled).and_return(true).at_least(:once)
      expect { Al::Allocation.update_vm(vmh, vm) }.to raise_error(RuntimeError, /no ip4 addresses left/)
    end

    it "allocates standard-gpu VM correctly on GEX44 host" do
      vmh = VmHost.first
      # Set the host to match GEX44 specs - it is an x64 host, but with one thread per core
      vmh.update(arch: "x64", total_dies: 1, total_sockets: 1, total_cpus: 14, total_cores: 14, used_cores: 2)
      used_cores = vmh.used_cores
      used_memory = vmh.used_hugepages_1g

      vm = create_vm_from_size("standard-gpu-6", "x64")
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      vm.reload

      expect(vm.vcpus).to eq(6)
      expect(vm.cores).to eq(6)
      expect(vm.memory_gib).to eq(32)
      expect(vmh.used_cores).to eq(used_cores + vm.cores)
      expect(vmh.used_hugepages_1g).to eq(used_memory + vm.memory_gib)
    end

    it "allocates standard VM correctly on arm64 host" do
      vmh = create_vm_host(arch: "arm64", total_cpus: 8, total_cores: 8, used_cores: 1, total_hugepages_1g: 26, used_hugepages_1g: 3, net6: "2001:db8::/64")
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { it.id = vmh.id }
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..8).each do |i|
        VmHostCpu.create(vm_host_id: vmh.id, cpu_number: i, spdk: i < 1)
      end

      used_cores = vmh.used_cores
      used_memory = vmh.used_hugepages_1g

      vm = create_vm_from_size("standard-2", "arm64")
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      vm.reload

      # Expect the number of vcpus to match the number of cores
      expect(vm.vcpus).to eq(2)
      expect(vm.cores).to eq(2)
      expect(vm.memory_gib).to eq(6)
      expect(vmh.used_cores).to eq(used_cores + vm.cores)
      expect(vmh.used_hugepages_1g).to eq(used_memory + vm.memory_gib)
    end

    it "only allocates standard-gpu vms on GEX44 host" do
      vmh = VmHost.first
      vmh.update(arch: "x64", total_dies: 1, total_sockets: 1, total_cpus: 14, total_cores: 14, used_cores: 2)

      vm = create_vm
      expect {
        described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
          {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      }.to raise_error(RuntimeError, /no space left on any eligible host/)
    end
  end

  describe "project and host selection with slices" do
    let(:vol) {
      [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => false, "boot" => false}]
    }

    before do
      vmh = create_vm_host(total_mem_gib: 64, total_sockets: 2, total_dies: 2, total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, net6: "fd10:9b0b:6b4b:8fbb::/64")
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { it.id = vmh.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..16).each do |i|
        VmHostCpu.create(vm_host_id: vmh.id, cpu_number: i, spdk: i < 2)
      end
    end

    it "creates a VM with no slice if slices not accepted" do
      vmh = VmHost.first
      expect(vmh.accepts_slices).to be(false)

      vm = create_vm
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      expect(al).not_to be_nil
      al.update(vm)

      # The VM should be allocated with no slice
      expect(vm.vm_host_slice).to be_nil
    end

    it "creates a VM in slice if slices are accepted" do
      vmh = VmHost.first
      vmh.allow_slices
      expect(vmh.accepts_slices).to be(true)

      vm = create_vm
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      expect(al).not_to be_nil
      al.update(vm)

      # The VM should be allocated with no slice
      expect(vm.vm_host_slice).not_to be_nil
    end

    it "creates a VM with no slice on a host that does not accept slices" do
      vmh = VmHost.first
      expect(vmh.accepts_slices).to be(false)

      vm = create_vm
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: false))
      expect(al).not_to be_nil
      al.update(vm)

      # The VM should be allocated with no slice
      expect(vm.vm_host_slice).to be_nil
    end

    it "fails to create a VM with no slice if no host available" do
      vmh = VmHost.first
      vmh.allow_slices
      expect(vmh.accepts_slices).to be(true)

      vm = create_vm
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: false))
      expect(al).to be_nil
    end
  end

  describe "slice selection" do
    let(:vol) {
      [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => false, "boot" => false}]
    }

    before do
      vmh = create_vm_host(total_mem_gib: 64, total_sockets: 2, total_dies: 2, net6: "fd10:9b0b:6b4b:8fbb::/64", total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, accepts_slices: true)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { it.id = vmh.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..16).each do |i|
        VmHostCpu.create(vm_host_id: vmh.id, cpu_number: i, spdk: i < 2)
      end
    end

    it "slice allocation fails on overbooked host" do
      vh = VmHost.first
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh, family: "standard", allowed_cpus: (2..7), memory_gib: 24)
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl2", vh, family: "standard", allowed_cpus: (8..15), memory_gib: 32)

      vh.update(used_cores: 8, used_hugepages_1g: 24)

      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      expect(al).to be_nil
    end

    it "creates a vm with a slice" do
      vm = create_vm
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g

      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      al.update(vm)
      vmh.reload

      expected_slice_name = "#{vm.family}_#{vm.inhost_name}"

      # Validate the slice got created
      expect(vmh.slices.size).to eq(1)
      slice = vmh.slices.first
      expect(vm.vm_host_slice).not_to be_nil
      expect(vm.vm_host_slice.id).to eq(slice.id)

      # All this mocking is needed to generate params_json so we can check the slice_name
      ps = PrivateSubnet.create_with_id(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "2001:db8::/64", net4: "10.0.0.0/24", project_id: vm.project.id)
      nic = instance_double(Nic, id: "n2")
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(nic).to receive(:private_ipv4).and_return(NetAddr::IPv4Net.parse("192.168.1.0/32"))
      expect(nic).to receive(:private_ipv6).and_return(NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64"))
      expect(nic).to receive(:ubid_to_tap_name).and_return("")
      expect(nic).to receive(:mac).and_return("")
      expect(nic).to receive(:private_ipv4_gateway).and_return("")
      expect(vm).to receive(:nics).and_return([nic]).at_least(1)
      expect(JSON.parse(vm.params_json).fetch("slice_name")).to eq(expected_slice_name + ".slice")

      # Validate the slice properties
      expect(slice.name).to eq(expected_slice_name)
      expect(slice.allowed_cpus_cgroup).to eq("2-3")
      expect(slice.is_shared).to be(false)
      expect(slice.cores).to eq(1)
      expect(slice.total_cpu_percent).to eq(200)
      expect(slice.total_memory_gib).to eq(8)
      expect(slice.vm_host_id).to eq(vmh.id)

      expect(vmh.used_cores).to eq(used_cores + slice.cores)
      expect(vmh.used_hugepages_1g).to eq(used_hugepages_1g + slice.total_memory_gib)
    end

    it "allows multiple allocations with slice" do
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { it.available_storage_gib }

      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      al1.update(vm1)
      al2.update(vm2)
      vmh.reload
      expect(vmh.used_cores).to eq(used_cores + vm1.vm_host_slice.cores + vm2.vm_host_slice.cores)
      expect(vmh.used_hugepages_1g).to eq(used_hugepages_1g + vm1.vm_host_slice.total_memory_gib + vm2.vm_host_slice.total_memory_gib)
      expect(vmh.storage_devices.sum { it.available_storage_gib }).to eq(available_storage - 10)
    end

    it "finds a disjoined cpuset" do
      vh = VmHost.first
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh, family: "standard", allowed_cpus: (2..5), memory_gib: 16)
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl2", vh, family: "standard", allowed_cpus: (8..11), memory_gib: 16)

      vm = create_vm(vcpus: 4, memory_gib: 16, cpu_percent_limit: 400)
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      al.update(vm)
      vh.reload

      slice = vm.vm_host_slice
      expect(slice).not_to be_nil
      expect(slice.allowed_cpus_cgroup).to eq("6-7,12-13")
    end

    it "places a burstable vm in an new slice" do
      vh = VmHost.first
      first_slice = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh, family: "burstable", allowed_cpus: (2..3), memory_gib: 8, is_shared: true).subject
      first_slice.update(used_cpu_percent: 200, used_memory_gib: 8, enabled: true)
      vh.update(total_cores: 4, total_cpus: 8, used_cores: 2, total_hugepages_1g: 27, used_hugepages_1g: 10)
      vh.reload
      used_cores = vh.used_cores
      used_hugepages_1g = vh.used_hugepages_1g

      vm = create_vm(family: "burstable", vcpus: 1, memory_gib: 2, cpu_percent_limit: 50, cpu_burst_percent_limit: 50)
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true, require_shared_slice: true))
      expect(al).not_to be_nil

      al.update(vm)
      vh.reload

      expect(vm.vcpus).to eq(1)
      expect(vm.cores).to eq(0)
      expect(vm.memory_gib).to eq(2)

      slice = vm.vm_host_slice
      expect(slice).not_to be_nil
      expect(slice.id).not_to eq(first_slice.id)
      expect(slice.allowed_cpus_cgroup).to eq("4-5")
      expect(slice.cores).to eq(1)
      expect(slice.total_cpu_percent).to eq(200)
      expect(slice.used_cpu_percent).to eq(50)
      expect(slice.total_memory_gib).to eq(8)
      expect(slice.used_memory_gib).to eq(2)
      expect(vh.slices.size).to eq(2)
      expect(vh.used_cores).to eq(used_cores + slice.cores)
      expect(vh.used_hugepages_1g).to eq(used_hugepages_1g + slice.total_memory_gib)
    end

    it "places a burstable vm in an existing slice" do
      vh = VmHost.first
      slice1 = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh, family: "standard", allowed_cpus: (2..5), memory_gib: 16, is_shared: false).subject
      slice2 = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl2", vh, family: "burstable", allowed_cpus: (6..7), memory_gib: 8, is_shared: true).subject
      slice1.update(used_cpu_percent: 400, used_memory_gib: 16, enabled: true)
      slice2.update(used_cpu_percent: 100, used_memory_gib: 4, enabled: true)
      vh.update(total_cores: 4, total_cpus: 8, used_cores: 4, total_hugepages_1g: 27, used_hugepages_1g: 26)
      vh.reload
      used_cores = vh.used_cores
      used_hugepages_1g = vh.used_hugepages_1g

      vm = create_vm(family: "burstable", vcpus: 2, memory_gib: 4, cpu_percent_limit: 100, cpu_burst_percent_limit: 100)
      req = create_req(vm, vol, use_slices: true, require_shared_slice: true)

      candidates = Al::Allocation.candidate_hosts(req)
      expect(candidates.size).to eq(1)

      al = Al::Allocation.new(candidates[0], req)
      expect(al.is_valid).to be_truthy

      al.update(vm)
      vh.reload

      slice = vm.vm_host_slice
      expect(slice).not_to be_nil
      expect(slice.id).to eq(slice2.id)
      expect(vh.used_cores).to eq(used_cores)
      expect(vh.used_hugepages_1g).to eq(used_hugepages_1g)
    end

    it "prefers a host with available slice for burstables" do
      vh1 = VmHost.first
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh1, family: "standard", allowed_cpus: (2..5), memory_gib: 16, is_shared: false)
        .subject
        .update(used_cpu_percent: 400, used_memory_gib: 16, enabled: true) # Full
      Prog::Vm::VmHostSliceNexus.assemble_with_host("sl2", vh1, family: "burstable", allowed_cpus: (6..7), memory_gib: 8, is_shared: true)
        .subject
        .update(used_cpu_percent: 100, used_memory_gib: 4, enabled: true)  # Partially filled in
      vh1.update(total_cores: 4, total_cpus: 8, used_cores: 4, total_hugepages_1g: 27, used_hugepages_1g: 26)
      vh1.reload

      # Create a second host
      vh2 = create_vm_host(total_sockets: 2, total_dies: 2, total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2, accepts_slices: true)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vh2.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vh2.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vh2.id, version: "v1", allocation_weight: 100) { it.id = vh2.id }
      Address.create_with_id(cidr: "1.1.2.0/30", routed_to_host_id: vh2.id)
      PciDevice.create_with_id(vm_host_id: vh2.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vh2.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      vh2.update(used_cores: 4, used_hugepages_1g: 26)
      vh2.reload

      # Expect the first host to be picked, to fill in the available slice
      vm = create_vm(family: "burstable", vcpus: 1, memory_gib: 2, cpu_percent_limit: 50, cpu_burst_percent_limit: 50)
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true, require_shared_slice: true))
      expect(al).not_to be_nil

      al.update(vm)
      expect(vm.vm_host.id).to eq(vh1.id)
    end

    it "fails if slice is not enabled" do
      vh = VmHost.first
      slice1 = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl1", vh, family: "standard", allowed_cpus: (2..5), memory_gib: 16, is_shared: false).subject
      slice2 = Prog::Vm::VmHostSliceNexus.assemble_with_host("sl2", vh, family: "burstable", allowed_cpus: (6..7), memory_gib: 8, is_shared: true).subject
      slice1.update(used_cpu_percent: 400, used_memory_gib: 16, enabled: true)
      slice2.update(used_cpu_percent: 100, used_memory_gib: 4, enabled: true)
      vh.update(total_cores: 4, total_cpus: 8, used_cores: 4, total_hugepages_1g: 27, used_hugepages_1g: 26)

      vm = create_vm(family: "burstable", vcpus: 1, memory_gib: 2, cpu_percent_limit: 50, cpu_burst_percent_limit: 50)
      req = create_req(vm, vol, use_slices: true, require_shared_slice: true)

      candidates = Al::Allocation.candidate_hosts(req)
      expect(candidates.size).to eq(1)

      al = Al::Allocation.new(candidates[0], req)
      expect(al.is_valid).to be_truthy

      # simulate the slice going away while being allocated
      slice2.update(enabled: false, used_cpu_percent: 0, used_memory_gib: 0)

      expect { al.update(vm) }.to raise_error RuntimeError, "failed to update slice"
    end

    it "allocates with no slice if no host available for standard" do
      # mark the first host as full
      vmh1 = VmHost.first
      vmh1.update(used_cores: vmh1.total_cores, used_hugepages_1g: vmh1.total_hugepages_1g)

      # create a second host
      vmh2 = create_vm_host(accepts_slices: false, net6: "2001:db8::/64", total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh2.id, version: "v1", allocation_weight: 100) { it.id = vmh2.id }
      Address.create_with_id(cidr: "1.2.1.0/30", routed_to_host_id: vmh2.id)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..16).each do |i|
        VmHostCpu.create(vm_host_id: vmh2.id, cpu_number: i, spdk: i < 2)
      end

      vm = create_vm
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true))
      expect(al).not_to be_nil
      al.update(vm)

      expect(vm.vm_host.id).to eq(vmh2.id)
      expect(vm.vm_host_slice).to be_nil
      expect(vm.cores).to eq(1)
    end

    it "fails if no host with accepts_slices is available for burstable" do
      # mark the first host as full
      vmh1 = VmHost.first
      vmh1.update(used_cores: vmh1.total_cores, used_hugepages_1g: vmh1.total_hugepages_1g)

      # create a second host
      vmh2 = create_vm_host(accepts_slices: false, net6: "2001:db8::/64", total_cpus: 16, total_cores: 8, used_cores: 1, total_hugepages_1g: 54, used_hugepages_1g: 2)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh2.id, version: "v1", allocation_weight: 100) { it.id = vmh2.id }
      Address.create_with_id(cidr: "1.2.1.0/30", routed_to_host_id: vmh2.id)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..16).each do |i|
        VmHostCpu.create(vm_host_id: vmh2.id, cpu_number: i, spdk: i < 2)
      end

      vm = create_vm(family: "burstable", vcpus: 1, memory_gib: 2, cpu_percent_limit: 50, cpu_burst_percent_limit: 50)
      al = Al::Allocation.best_allocation(create_req(vm, vol, use_slices: true, require_shared_slice: true))
      expect(al).to be_nil
    end

    it "allocates VMs in slice correctly on arm64 host" do
      # create an arm64 host
      vmh = create_vm_host(accepts_slices: true, arch: "arm64", total_cpus: 12, total_cores: 12, used_cores: 1, total_hugepages_1g: 43, used_hugepages_1g: 3, net6: "2001:db8::/64")
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { it.id = vmh.id }
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
      (0..12).each do |i|
        VmHostCpu.create(vm_host_id: vmh.id, cpu_number: i, spdk: i < 1)
      end

      used_cores = vmh.used_cores
      used_memory = vmh.used_hugepages_1g

      # Create a standard VM in a slice
      vm = create_vm_from_size("standard-2", "arm64")
      described_class.allocate(vm, [{"size_gib" => 40, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 40, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      vm.reload

      # Verify everything
      expect(vm.vcpus).to eq(2)
      expect(vm.cores).to eq(0)
      expect(vm.memory_gib).to eq(6)
      slice = vm.vm_host_slice
      expect(slice).not_to be_nil
      expect(slice.cores).to eq(2)
      expect(slice.total_memory_gib).to eq(6)
      expect(slice.total_cpu_percent).to eq(200)
      expect(slice.used_cpu_percent).to eq(200)
      expect(slice.used_memory_gib).to eq(6)

      expect(vmh.used_cores).to eq(used_cores + slice.cores)
      expect(vmh.used_hugepages_1g).to eq(used_memory + slice.total_memory_gib)

      # Create a burstable VM in a slice
      vm_b1 = create_vm_from_size("burstable-1", "arm64")
      described_class.allocate(vm_b1, [{"size_gib" => 20, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 20, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      vm_b1.reload

      # Verify everything
      expect(vm_b1.vcpus).to eq(1)
      expect(vm_b1.cores).to eq(0)
      expect(vm_b1.memory_gib).to eq(1)
      slice_b = vm_b1.vm_host_slice
      slice_b.update(enabled: true) # we don't have a proc to do that
      expect(slice_b).not_to be_nil
      expect(slice_b.cores).to eq(2)
      expect(slice_b.total_memory_gib).to eq(6)
      expect(slice_b.total_cpu_percent).to eq(200)
      expect(slice_b.used_cpu_percent).to eq(50)
      expect(slice_b.used_memory_gib).to eq(1)

      expect(vmh.used_cores).to eq(used_cores + slice.cores + slice_b.cores)
      expect(vmh.used_hugepages_1g).to eq(used_memory + slice.total_memory_gib + slice_b.total_memory_gib)

      # Create a second burstable VM in a slice. It should go to the same slice
      vm_b2 = create_vm_from_size("burstable-2", "arm64")
      described_class.allocate(vm_b2, [{"size_gib" => 20, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 20, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      vm_b2.reload
      slice_b.reload

      # Verify everything
      expect(vm_b2.vcpus).to eq(2)
      expect(vm_b2.cores).to eq(0)
      expect(vm_b2.memory_gib).to eq(3)
      expect(vm_b2.vm_host_slice.id).to eq(slice_b.id)
      expect(slice_b.used_cpu_percent).to eq(150)
      expect(slice_b.used_memory_gib).to eq(4)

      # No change at the host level
      expect(vmh.used_cores).to eq(used_cores + slice.cores + slice_b.cores)
      expect(vmh.used_hugepages_1g).to eq(used_memory + slice.total_memory_gib + slice_b.total_memory_gib)
    end

    it "memory_gib_for_vcpus handles standard family" do
      vm = create_vm
      req = create_req(vm, vol)

      expect(req.memory_gib_for_vcpus(vm.vcpus)).to eq 8
    end

    it "memory_gib_for_vcpus returns correct ratio for standard-gpu" do
      vm = create_vm(family: "standard-gpu", arch: "x64", vcpus: 6, cpu_percent_limit: 600)
      req = create_req(vm, vol)

      expect(req.memory_gib_for_vcpus(vm.vcpus)).to eq 32
    end

    it "memory_gib_for_vcpus handles arm64" do
      vm = create_vm(family: "standard", arch: "arm64", vcpus: "2")
      req = create_req(vm, vol)

      expect(req.memory_gib_for_vcpus(vm.vcpus)).to eq 6
    end

    it "select_cpuset fails if not enough cpus" do
      vm = create_vm
      req = create_req(vm, vol)
      al = Scheduling::Allocator::VmHostSliceAllocation.new(nil, req, nil)

      vh = VmHost.first
      expect { al.select_cpuset(vh.id, 24) }.to raise_error "failed to allocate cpus"
    end
  end

  describe "#allocate_spdk_installation" do
    it "fails if total weight is zero" do
      si_1 = SpdkInstallation.new(allocation_weight: 0)
      si_2 = SpdkInstallation.new(allocation_weight: 0)

      expect { Al::StorageAllocation.allocate_spdk_installation([si_1, si_2]) }.to raise_error "Total weight of all eligible spdk_installations shouldn't be zero."
    end

    it "chooses the only one if one provided" do
      si_1 = SpdkInstallation.new(allocation_weight: 100) { it.id = SpdkInstallation.generate_uuid }
      expect(Al::StorageAllocation.allocate_spdk_installation([si_1])).to eq(si_1.id)
    end

    it "doesn't return the one with zero weight" do
      si_1 = SpdkInstallation.new(allocation_weight: 0) { it.id = SpdkInstallation.generate_uuid }
      si_2 = SpdkInstallation.new(allocation_weight: 100) { it.id = SpdkInstallation.generate_uuid }
      expect(Al::StorageAllocation.allocate_spdk_installation([si_1, si_2])).to eq(si_2.id)
    end
  end
end
