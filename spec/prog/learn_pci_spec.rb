# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnPci do
  describe "#make_model_instances" do
    let(:nvidia_gpu_with_audio) do
    end

    it "exits, saving model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
NUMANode:	1
IOMMUGroup:	13

Slot:	01:00.1
Class:	0403
Vendor:	10de
Device:	22bc
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS
      expect { lp.start }.to exit({"msg" => "created PciDevice records"}).and change {
        PciDevice.map { {vm_host_id: it.vm_host_id, slot: it.slot, device_class: it.device_class, vendor: it.vendor, device: it.device, numa_node: it.numa_node, iommu_group: it.iommu_group, vm_id: it.vm_id} }.sort_by { it[:slot] }
      }.from(
        []
      ).to(
        [
          {vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", numa_node: 1, iommu_group: 13, vm_id: nil},
          {vm_host_id: vmh.id, slot: "01:00.1", device_class: "0403", vendor: "10de", device: "22bc", numa_node: nil, iommu_group: 13, vm_id: nil}
        ]
      )
    end

    it "exits, updating existing model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      PciDevice.create(vm_host_id: vmh.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3)
      expect(lp.sshable).to receive(:cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13

Slot:	01:00.1
Class:	0403
Vendor:	10de
Device:	22bc
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS
      expect { lp.start }.to exit({"msg" => "created PciDevice records"}).and change {
        PciDevice.map { {vm_host_id: it.vm_host_id, slot: it.slot, device_class: it.device_class, vendor: it.vendor, device: it.device, numa_node: it.numa_node, iommu_group: it.iommu_group, vm_id: it.vm_id} }.sort_by { it[:slot] }
      }.from(
        [{vm_host_id: vmh.id, slot: "01:00.0", device_class: "dc", vendor: "vd", device: "dv", numa_node: 0, iommu_group: 3, vm_id: nil}]
      ).to(
        [
          {vm_host_id: vmh.id, slot: "01:00.0", device_class: "0300", vendor: "10de", device: "27b0", numa_node: nil, iommu_group: 13, vm_id: nil},
          {vm_host_id: vmh.id, slot: "01:00.1", device_class: "0403", vendor: "10de", device: "22bc", numa_node: nil, iommu_group: 13, vm_id: nil}
        ]
      )
    end

    it "ignores devices without iommu group" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Vendor:	10de
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
EOS
      expect(lp.make_model_instances).to eq([])
    end

    it "can raise a data parse error" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      lp = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(lp.sshable).to receive(:cmd).with("/usr/bin/lspci -vnmm -d 10de::").and_return(<<EOS)
Slot:	01:00.0
Class:	0300
Device:	27b0
SVendor:	10de
SDevice:	16fa
Rev:	a1
IOMMUGroup:	13
EOS

      expect { lp.make_model_instances }.to raise_error RuntimeError, "BUG: lspci parse failed"
    end
  end
end
