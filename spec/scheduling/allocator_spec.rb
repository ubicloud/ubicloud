# frozen_string_literal: true

require_relative "../model/spec_helper"
require "netaddr"

Al = Scheduling::Allocator
TestAllocation = Struct.new(:score, :is_valid)
TestResourceAllocation = Struct.new(:utilization, :is_valid)
RSpec.describe Al do
  let(:vm) {
    Vm.new(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "loc1", ip4_enabled: "true", created_at: Time.now, unix_user: "", public_key: "", boot_image: "ubuntu-jammy").tap {
      _1.id = "2464de61-7501-8374-9ab0-416caebe31da"
    }
  }

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

    it "fails if no valid allocation is found" do
      expect(Al::Allocation).to receive(:best_allocation).and_return(nil)
      expect { described_class.allocate(vm, storage_volumes) }.to raise_error RuntimeError, "Vm[#{vm.ubid}] no space left on any eligible host"
    end

    it "persists valid allocation" do
      al = instance_double(Al::Allocation)
      expect(Al::Allocation).to receive(:best_allocation)
        .with(Al::Request.new(
          "2464de61-7501-8374-9ab0-416caebe31da", 1, 8, 33,
          [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
            [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
          "ubuntu-jammy", false, false, true, Config.allocator_target_host_utilization, "x64", ["accepting"], [], [], []
        )).and_return(al)
      expect(al).to receive(:update)

      described_class.allocate(vm, storage_volumes)
    end
  end

  describe "candidate_selection" do
    let(:req) {
      Al::Request.new(
        "2464de61-7501-8374-9ab0-416caebe31da", 2, 8, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, false, true, 0.65, "x64", ["accepting"], [], [], []
      )
    }

    it "selects the best allocation candidate" do
      candidates = [[0.1, false], [5, true], [0.9, true], [99, true]]
      candidates.each { expect(Al::Allocation).to receive(:new).once.ordered.with(_1, req).and_return TestAllocation.new(_1[0], _1[1]) }
      expect(Al::Allocation).to receive(:candidate_hosts).with(req).and_return(candidates)
      expect(Al::Allocation).to receive(:random_score).and_return(0).at_least(:once)

      expect(Al::Allocation.best_allocation(req)).to eq(TestAllocation.new(0.9, true))
    end

    it "disqualifies invalid candidates" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 6, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "draining", arch: "x64", location: "loc1", total_cores: 8, used_cores: 1, total_hugepages_1g: 8, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh3 = VmHost.create(allocation_state: "accepting", arch: "arm64", location: "loc1", total_cores: 8, used_cores: 0, total_hugepages_1g: 8, used_hugepages_1g: 0) { _1.id = Sshable.create_with_id.id }
      vmh4 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 8, used_cores: 6, total_hugepages_1g: 8, used_hugepages_1g: 5) { _1.id = Sshable.create_with_id.id }
      vmh5 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "github-runners", total_cores: 8, used_cores: 6, total_hugepages_1g: 80, used_hugepages_1g: 5) { _1.id = Sshable.create_with_id.id }

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
      vmh = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 3, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      sd1 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 123, total_storage_gib: 345)
      sd2 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 12, total_storage_gib: 99)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now)

      expect(Al::Allocation.candidate_hosts(req))
        .to eq([{location: vmh.location,
                 num_storage_devices: 2,
                 storage_devices: [{"available_storage_gib" => sd2.available_storage_gib, "id" => sd2.id, "total_storage_gib" => sd2.total_storage_gib},
                   {"available_storage_gib" => sd1.available_storage_gib, "id" => sd1.id, "total_storage_gib" => sd1.total_storage_gib}],
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
                 vm_provisioning_count: 0}])
    end

    it "retrieves provisioning count" do
      vmh = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 3, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      sd1 = StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 123, total_storage_gib: 345)
      Vm.create_with_id(vm_host_id: vmh.id, family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "loc1", ip4_enabled: false, created_at: Time.now, unix_user: "", public_key: "", boot_image: "")
      Vm.create_with_id(vm_host_id: vmh.id, family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "loc1", ip4_enabled: false, created_at: Time.now, unix_user: "", public_key: "", boot_image: "ubuntu-jammy")
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now)

      expect(Al::Allocation.candidate_hosts(req))
        .to eq([{location: vmh.location,
                 num_storage_devices: 1,
                 storage_devices: [{"available_storage_gib" => sd1.available_storage_gib, "id" => sd1.id, "total_storage_gib" => sd1.total_storage_gib}],
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
                 vm_provisioning_count: 2}])
    end

    it "applies host filter" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      req.host_filter = [vmh2.id]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
    end

    it "applies location filter" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc2", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      req.location_filter = ["loc1"]
      cand = Al::Allocation.candidate_hosts(req)

      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh1.id)
    end

    it "retrieves candidates with enough storage devices" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor2", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      req.distinct_storage_devices = true
      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
    end

    it "retrieves candidates with available ipv4 addresses if ip4_enabled" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/32", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh1.id)
    end

    it "retrieves candidates without available ipv4 addresses if not ip4_enabled" do
      req.ip4_enabled = false
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/32", routed_to_host_id: vmh2.id)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(2)
    end

    it "retrieves candidates with gpu if gpu_enabled" do
      vmh1 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      vmh2 = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", total_cores: 7, used_cores: 4, total_hugepages_1g: 10, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      StorageDevice.create_with_id(vm_host_id: vmh1.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh2.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh1.id)
      Address.create_with_id(cidr: "2.1.1.0/30", routed_to_host_id: vmh2.id)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "02:00.0", device_class: "0300", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 9)
      PciDevice.create_with_id(vm_host_id: vmh2.id, slot: "03:00.0", device_class: "1234", vendor: "vd", device: "dv3", numa_node: 0, iommu_group: 11)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh1.id, activated_at: Time.now)
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh2.id, activated_at: Time.now)

      req.gpu_enabled = true
      cand = Al::Allocation.candidate_hosts(req)
      expect(cand.size).to eq(1)
      expect(cand.first[:vm_host_id]).to eq(vmh2.id)
      expect(cand.first[:available_iommu_groups]).to eq([3, 9])
    end
  end

  describe "Allocation" do
    let(:req) {
      Al::Request.new(
        "2464de61-7501-8374-9ab0-416caebe31da", 2, 8, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, false, true, 0.65, "x64", ["accepting"], [], [], []
      )
    }
    let(:vmhds) {
      {location: "loc1",
       num_storage_devices: 2,
       storage_devices: [{"available_storage_gib" => 10, "id" => "sd1id", "total_storage_gib" => 10},
         {"available_storage_gib" => 101, "id" => "sd2id", "total_storage_gib" => 91}],
       total_storage_gib: 111,
       available_storage_gib: 101,
       total_cores: 8,
       used_cores: 3,
       total_hugepages_1g: 22,
       used_hugepages_1g: 9,
       num_gpus: 0,
       available_gpus: 0,
       vm_host_id: "the_id",
       vm_provisioning_count: 0}
    }

    it "initializes individual resource allocations" do
      expect(Al::VmHostAllocation).to receive(:new).with(:used_cores, vmhds[:total_cores], vmhds[:used_cores], req.cores).and_return(instance_double(Al::VmHostAllocation, utilization: req.target_host_utilization, is_valid: true))
      expect(Al::VmHostAllocation).to receive(:new).with(:used_hugepages_1g, vmhds[:total_hugepages_1g], vmhds[:used_hugepages_1g], req.mem_gib).and_return(instance_double(Al::VmHostAllocation, utilization: req.target_host_utilization, is_valid: true))
      expect(Al::StorageAllocation).to receive(:new).with(vmhds, req).and_return(instance_double(Al::StorageAllocation, utilization: req.target_host_utilization, is_valid: true))

      allocation = Al::Allocation.new(vmhds, req)
      expect(allocation.score).to eq 0
      expect(allocation.is_valid).to be_truthy
    end

    it "is valid only if all resource allocations are valid" do
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, false))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))

      allocation = Al::Allocation.new(vmhds, req)
      expect(allocation.score).to eq 0
      expect(allocation.is_valid).to be_falsy
    end

    it "has score of 0 if all resources are at target utilization" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))

      expect(Al::Allocation.new(vmhds, req).score).to eq 0
    end

    it "is penalized if utilization is below target" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization * 0.9, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 0.9, true))
      expect(Al::Allocation.new(vmhds, req).score).to be > 0
    end

    it "penalizes over-utilization more than under-utilization" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_low_utilization = Al::Allocation.new(vmhds, req).score

      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization * 1.01, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization * 1.01, true))
      score_over_target = Al::Allocation.new(vmhds, req).score

      expect(score_over_target).to be > score_low_utilization
    end

    it "penalizes imbalance" do
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      score_balance = Al::Allocation.new(vmhds, req).score

      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.4, true))
      expect(Al::VmHostAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.5, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0.6, true))
      score_imbalance = Al::Allocation.new(vmhds, req).score

      expect(score_imbalance).to be > score_balance
    end

    it "penalizes concurrent provisioning for github runners" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      vmhds[:location] = "github-runners"
      vmhds[:vm_provisioning_count] = 1
      expect(Al::Allocation.new(vmhds, req).score).to eq(0.5)
    end

    it "penalizes AX161 github runners" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(req.target_host_utilization, true))
      vmhds[:location] = "github-runners"
      vmhds[:total_cores] = 32
      expect(Al::Allocation.new(vmhds, req).score).to eq(0.5)
    end

    it "respects location preferences" do
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_no_preference = Al::Allocation.new(vmhds, req).score

      req.location_preference = ["loc1"]
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(0, true))
      expect(Al::StorageAllocation).to receive(:new).and_return(TestResourceAllocation.new(0, true))
      score_preference_met = Al::Allocation.new(vmhds, req).score

      req.location_preference = ["loc2"]
      expect(Al::VmHostAllocation).to receive(:new).twice.and_return(TestResourceAllocation.new(req.target_host_utilization, true))
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
        "2464de61-7501-8374-9ab0-416caebe31da", 2, 8, 33,
        [[1, {"use_bdev_ubi" => true, "skip_sync" => false, "size_gib" => 22, "boot" => false}],
          [0, {"use_bdev_ubi" => false, "skip_sync" => true, "size_gib" => 11, "boot" => true}]],
        "ubuntu-jammy", false, 0.65, "x64", ["accepting"], [], [], []
      )
    }
    let(:vmhds) {
      {location: "loc1",
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
      vmh = VmHost.create(allocation_state: "accepting", arch: "x64", location: "loc1", net6: "fd10:9b0b:6b4b:8fbb::/64", total_cores: 7, used_cores: 5, total_hugepages_1g: 18, used_hugepages_1g: 2) { _1.id = Sshable.create_with_id.id }
      BootImage.create_with_id(name: "ubuntu-jammy", version: "20220202", vm_host_id: vmh.id, activated_at: Time.now)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100)
      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor2", available_storage_gib: 90, total_storage_gib: 90)
      SpdkInstallation.create(vm_host_id: vmh.id, version: "v1", allocation_weight: 100) { _1.id = vmh.id }
      Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: vmh.id)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "vd", device: "dv1", numa_node: 0, iommu_group: 3)
      PciDevice.create_with_id(vm_host_id: vmh.id, slot: "01:00.1", device_class: "0420", vendor: "vd", device: "dv2", numa_node: 0, iommu_group: 3)
    end

    def create_vm
      Vm.create_with_id(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "loc1", ip4_enabled: false, created_at: Time.now, unix_user: "", public_key: "", boot_image: "ubuntu-jammy")
    end

    def create_req(vm, storage_volumes, target_host_utilization: 0.55, distinct_storage_devices: false, gpu_enabled: false, allocation_state_filter: ["accepting"], host_filter: [], location_filter: [], location_preference: [])
      Al::Request.new(
        vm.id,
        vm.cores,
        vm.mem_gib,
        storage_volumes.map { _1["size_gib"] }.sum,
        storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
        vm.boot_image,
        distinct_storage_devices,
        gpu_enabled,
        true,
        target_host_utilization,
        vm.arch,
        allocation_state_filter,
        host_filter,
        location_filter,
        location_preference
      )
    end

    it "updates resources" do
      vm = create_vm
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { _1.available_storage_gib }
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      vmh.reload
      expect(vm.vm_storage_volumes.detect { _1.disk_index == 0 }.size_gib).to eq(85)
      expect(vm.vm_storage_volumes.detect { _1.disk_index == 1 }.size_gib).to eq(95)
      expect(StorageDevice[vm.vm_storage_volumes.detect { _1.disk_index == 0 }.storage_device_id].name).to eq("stor2")
      expect(StorageDevice[vm.vm_storage_volumes.detect { _1.disk_index == 1 }.storage_device_id].name).to eq("stor1")
      expect(used_cores + vm.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm.mem_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 180).to eq(vmh.storage_devices.sum { _1.available_storage_gib })
      expect(vmh.pci_devices.map { _1.vm_id }).to eq([nil, nil])
    end

    it "updates pci devices" do
      vm = create_vm
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { _1.available_storage_gib }
      described_class.allocate(vm, [{"size_gib" => 85, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false},
        {"size_gib" => 95, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}], gpu_enabled: true)
      vmh.reload
      expect(vm.vm_storage_volumes.detect { _1.disk_index == 0 }.size_gib).to eq(85)
      expect(vm.vm_storage_volumes.detect { _1.disk_index == 1 }.size_gib).to eq(95)
      expect(StorageDevice[vm.vm_storage_volumes.detect { _1.disk_index == 0 }.storage_device_id].name).to eq("stor2")
      expect(StorageDevice[vm.vm_storage_volumes.detect { _1.disk_index == 1 }.storage_device_id].name).to eq("stor1")
      expect(used_cores + vm.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm.mem_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 180).to eq(vmh.storage_devices.sum { _1.available_storage_gib })
      expect(vmh.pci_devices.map { _1.vm_id }).to eq([vm.id, vm.id])
    end

    it "allows concurrent allocations" do
      vmh = VmHost.first
      used_cores = vmh.used_cores
      used_hugepages_1g = vmh.used_hugepages_1g
      available_storage = vmh.storage_devices.sum { _1.available_storage_gib }
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      al2.update(vm2)
      vmh.reload
      expect(used_cores + vm1.cores + vm2.cores).to eq(vmh.used_cores)
      expect(used_hugepages_1g + vm1.mem_gib + vm2.mem_gib).to eq(vmh.used_hugepages_1g)
      expect(available_storage - 10).to eq(vmh.storage_devices.sum { _1.available_storage_gib })
    end

    it "fails concurrent allocations if core constraints are violated" do
      vmh = VmHost.first
      vmh.update(used_cores: vmh.used_cores + 1)
      vm1 = create_vm
      vm2 = create_vm
      al1 = Al::Allocation.best_allocation(create_req(vm, vol))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(Sequel::CheckConstraintViolation, /core_allocation_limit/)
    end

    it "fails concurrent allocations if memory constraints are violated" do
      vmh = VmHost.first
      vmh.update(used_hugepages_1g: vmh.used_hugepages_1g + 1)
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
      al1 = Al::Allocation.best_allocation(create_req(vm, vol, gpu_enabled: true))
      al2 = Al::Allocation.best_allocation(create_req(vm, vol, gpu_enabled: true))
      al1.update(vm1)
      expect { al2.update(vm2) }.to raise_error(RuntimeError, "concurrent GPU allocation")
    end

    it "creates volume without encryption key if storage is not encrypted" do
      vm = create_vm
      described_class.allocate(vm, vol)
      expect(StorageKeyEncryptionKey.count).to eq(0)
      expect(vm.reload.vm_storage_volumes.first.key_encryption_key_1_id).to be_nil
      nx = Prog::Vm::Nexus.new(Strand.new).tap {
        _1.instance_variable_set(:@vm, vm)
      }
      expect(nx.storage_secrets.count).to eq(0)
    end

    it "can have empty allocation state filter" do
      vmh = VmHost.first
      vmh.update(allocation_state: "draining")
      al = Al::Allocation.best_allocation(create_req(vm, vol, allocation_state_filter: []))
      expect(al).to be_truthy
    end

    it "creates volume with encryption key if storage is encrypted" do
      vm = create_vm
      described_class.allocate(vm, [{"size_gib" => 5, "use_bdev_ubi" => false, "skip_sync" => false, "encrypted" => true, "boot" => false}])
      expect(StorageKeyEncryptionKey.count).to eq(1)
      expect(vm.vm_storage_volumes.first.key_encryption_key_1_id).not_to be_nil
      nx = Prog::Vm::Nexus.new(Strand.new).tap {
        _1.instance_variable_set(:@vm, vm)
      }
      expect(nx.storage_secrets.count).to eq(1)
    end

    it "allocates the latest active boot image for boot volumes" do
      vmh = VmHost.first
      BootImage.where(vm_host_id: vmh.id).update(activated_at: nil)
      bi = BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "20230303", activated_at: Time.now)
      BootImage.create_with_id(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "20240404", activated_at: nil)
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
  end

  describe "#allocate_spdk_installation" do
    it "fails if total weight is zero" do
      si_1 = SpdkInstallation.new(allocation_weight: 0)
      si_2 = SpdkInstallation.new(allocation_weight: 0)

      expect { Al::StorageAllocation.allocate_spdk_installation([si_1, si_2]) }.to raise_error "Total weight of all eligible spdk_installations shouldn't be zero."
    end

    it "chooses the only one if one provided" do
      si_1 = SpdkInstallation.new(allocation_weight: 100) { _1.id = SpdkInstallation.generate_uuid }
      expect(Al::StorageAllocation.allocate_spdk_installation([si_1])).to eq(si_1.id)
    end

    it "doesn't return the one with zero weight" do
      si_1 = SpdkInstallation.new(allocation_weight: 0) { _1.id = SpdkInstallation.generate_uuid }
      si_2 = SpdkInstallation.new(allocation_weight: 100) { _1.id = SpdkInstallation.generate_uuid }
      expect(Al::StorageAllocation.allocate_spdk_installation([si_1, si_2])).to eq(si_2.id)
    end
  end
end
