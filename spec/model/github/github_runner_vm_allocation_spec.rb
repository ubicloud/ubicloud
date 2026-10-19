# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunnerVmAllocation do
  let(:project) { Project.create(name: "runner-service") }
  let(:vm_host) { create_vm_host(location_id: Location::HETZNER_FSN1_ID, net6: "2a01:4f8:173:1ed3::/64", ip6: "2a01:4f8:173:1ed3::2") }
  let(:storage_device) { StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 1000, available_storage_gib: 925) }
  let(:slice) { VmHostSlice.create(vm_host_id: vm_host.id, name: "standard_vm", family: "standard", enabled: true, cores: 1, total_cpu_percent: 200, used_cpu_percent: 200, total_memory_gib: 8, used_memory_gib: 8) }
  let(:address) { Address.create(cidr: "1.1.1.0/30", routed_to_host_id: vm_host.id) }
  let(:storage_volumes) { [{"size_gib" => 75, "boot" => true, "encrypted" => true, "track_written" => false, "vring_workers" => 1}] }

  let(:held_vm) {
    vm = create_vm(name: "held", project_id: project.id, location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2404",
      vm_host_id: vm_host.id, vm_host_slice_id: slice.id, ip4_enabled: true, display_state: "deleting", local_vetho_ip: "169.254.0.2/32")
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 75, disk_index: 0, storage_device_id: storage_device.id)
    AssignedVmAddress.create(dst_vm_id: vm.id, address_id: address.id, ip: "1.1.1.1")
    vm
  }

  let(:new_vm) {
    vm = create_vm(name: "new", project_id: project.id, location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2404", ip4_enabled: true)
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 75, disk_index: 0)
    Sshable.create_with_id(vm, host: "temp_#{vm.id}")
    vm
  }

  def hold(vm = held_vm, label: "ubicloud-standard-2-ubuntu-2404", created_at: Time.now, generation: 1)
    described_class.create(vm_id: vm.id, label:, location_id: vm.location_id, vm_host_id: vm.vm_host_id, created_at:, generation:)
  end

  before do
    allow(Config).to receive_messages(github_runner_service_project_id: project.id, github_runner_vm_allocation_ratio: 1.0)
    BootImage.create(name: "github-ubuntu-2404", version: "20260101", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 75)
    create_vhost_block_backend(vm_host_id: vm_host.id)
  end

  describe ".label_for" do
    it "returns the label of a runner VM" do
      expect(described_class.label_for(new_vm, [75])).to eq("ubicloud-standard-2-ubuntu-2404")
    end

    it "returns the label of a pool VM" do
      pool_project = Project.create(name: "vm-pool")
      allow(Config).to receive(:vm_pool_project_id).and_return(pool_project.id)
      new_vm.update(project_id: pool_project.id)
      expect(described_class.label_for(new_vm, [75])).to eq("ubicloud-standard-2-ubuntu-2404")
    end

    it "returns nil when the ratio is 0" do
      allow(Config).to receive(:github_runner_vm_allocation_ratio).and_return(0.0)
      expect(described_class.label_for(new_vm, [75])).to be_nil
    end

    it "returns nil for VMs of other projects" do
      new_vm.update(project_id: Project.create(name: "other").id)
      expect(described_class.label_for(new_vm, [75])).to be_nil
    end

    it "returns nil for VMs with more than one storage volume" do
      expect(described_class.label_for(new_vm, [75, 10])).to be_nil
    end

    it "returns nil when the storage size does not match the label" do
      expect(described_class.label_for(new_vm, [80])).to be_nil
    end
  end

  describe ".claim" do
    it "returns false when the VM has no label" do
      hold
      expect(described_class.claim(new_vm, [{"size_gib" => 80}])).to be(false)
      expect(new_vm.reload.vm_host_id).to be_nil
    end

    it "returns false when there are no held resources with the label" do
      hold(label: "ubicloud-standard-4-ubuntu-2404")
      expect(described_class.claim(new_vm, storage_volumes)).to be(false)
    end

    it "does not use premium resources for a standard VM" do
      held_vm.update(family: "premium")
      hold(label: "ubicloud-premium-2-ubuntu-2404")
      expect(described_class.claim(new_vm, storage_volumes)).to be(false)
    end

    it "does not use held resources on a host that is not accepting" do
      hold
      vm_host.update(allocation_state: "draining")
      expect(described_class.claim(new_vm, storage_volumes)).to be(false)
    end

    it "moves the held resources to the new VM and destroys the held VM" do
      hold
      expect(Clog).to receive(:emit).with("vm allocation reused", instance_of(Hash)).and_call_original

      expect(described_class.claim(new_vm, storage_volumes)).to eq(1)

      new_vm.reload
      expect(new_vm.vm_host_id).to eq(vm_host.id)
      expect(new_vm.vm_host_slice_id).to eq(slice.id)
      expect(new_vm.allocated_at).not_to be_nil
      expect(new_vm.ephemeral_net6).not_to be_nil
      expect(new_vm.local_vetho_ip).not_to be_nil
      expect(new_vm.ip4_string).to eq("1.1.1.1")
      expect(new_vm.sshable.host).to eq("1.1.1.1")

      volume = new_vm.vm_storage_volumes.first
      expect(volume.storage_device_id).to eq(storage_device.id)
      expect(volume.boot_image.name).to eq("github-ubuntu-2404")
      expect(volume.vhost_block_backend_id).not_to be_nil
      expect(volume.vring_workers).to eq(1)

      # The held resources are moved, not returned to the host and allocated again.
      expect(storage_device.reload.available_storage_gib).to eq(925)
      expect([slice.reload.used_cpu_percent, slice.used_memory_gib]).to eq([200, 8])

      expect(held_vm).not_to exist
      expect(described_class.count).to eq(0)
    end

    it "uses the oldest held resources first" do
      newer_vm = create_vm(name: "newer", project_id: project.id, location_id: Location::GITHUB_RUNNERS_ID, boot_image: "github-ubuntu-2404",
        vm_host_id: vm_host.id, vm_host_slice_id: slice.id, display_state: "deleting", local_vetho_ip: "169.254.0.4/32")
      VmStorageVolume.create(vm_id: newer_vm.id, boot: true, size_gib: 75, disk_index: 0, storage_device_id: storage_device.id)
      hold(newer_vm)
      hold(created_at: Time.now - 30)

      expect(described_class.claim(new_vm, storage_volumes)).to eq(1)
      expect(held_vm).not_to exist
      expect(newer_vm).to exist
    end

    it "returns the generation of the reused resources" do
      hold(generation: 5)
      expect(described_class.claim(new_vm, storage_volumes)).to eq(5)
      expect(held_vm).not_to exist
    end
  end

  describe ".release_expired" do
    it "releases held resources older than a minute and on hosts that are not accepting" do
      expired = hold(created_at: Time.now - 61)
      draining_host = create_vm_host(allocation_state: "draining")
      draining_vm = create_vm(name: "draining", project_id: project.id, vm_host_id: draining_host.id)
      draining = hold(draining_vm)
      recent_vm = create_vm(name: "recent", project_id: project.id, vm_host_id: vm_host.id, local_vetho_ip: "169.254.0.6/32")
      recent = hold(recent_vm)

      described_class.release_expired

      expect(expired).not_to exist
      expect(draining).not_to exist
      expect(recent).to exist
      expect(Strand.where(prog: "Vm::Metal::Nexus", label: "release_held_allocation").select_order_map(:id)).to eq([held_vm.id, draining_vm.id].sort)
    end
  end

  describe "#release" do
    it "restarts the held VM's strand to release its resources" do
      allocation = hold
      allocation.release

      expect(allocation).not_to exist
      expect(held_vm.strand.label).to eq("release_held_allocation")
      expect(held_vm.destroying_set?).to be(true)
    end
  end
end
