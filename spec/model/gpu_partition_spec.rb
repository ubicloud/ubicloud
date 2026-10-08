# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GpuPartition do
  let(:vm_host) { create_vm_host }
  let(:project_id) { Project.create(name: "owner").id }
  let(:pci_devices) {
    (1..4).map { PciDevice.create(vm_host_id: vm_host.id, slot: "0#{it}:00.0", device_class: "0302", vendor: "10de", device: "3182", numa_node: 0, iommu_group: it) }
  }

  def create_partition(partition_id, pcis)
    described_class.create(vm_host_id: vm_host.id, partition_id:, gpu_count: pcis.size).tap do |gp|
      pcis.each { DB[:gpu_partitions_pci_devices].insert(gpu_partition_id: gp.id, pci_device_id: it.id) }
    end
  end

  it "can be owned by a project unless it overlaps a partition owned by a project" do
    all = create_partition(1, pci_devices)
    first_half = create_partition(2, pci_devices[0, 2])
    second_half = create_partition(3, pci_devices[2, 2])

    first_half.update(project_id:)
    expect(first_half.project.id).to eq(project_id)
    second_half.update(project_id: Project.create(name: "other").id)

    all.project_id = project_id
    expect(all.valid?).to be false
    expect(all.errors[:project_id]).to eq(["is set for a GPU partition overlapping another one owned by a project"])

    first_half.update(enabled: false)
  end
end
