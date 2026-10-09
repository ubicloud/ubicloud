# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnGpuPartitions do
  subject(:lgp) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }

  let(:vm_host) { create_vm_host }
  let(:gpus) {
    [["12:00.0", 0], ["f1:00.0", 1]].map.with_index do |(slot, numa_node), iommu_group|
      PciDevice.create(vm_host_id: vm_host.id, slot:, device_class: "0302", vendor: "10de", device: "3182", numa_node:, iommu_group:)
    end
  }

  def nvidia_smi_gpu(bus_id, module_id, with_bus_id: true)
    <<~GPU
      GPU #{bus_id}
          Product Name                                       : NVIDIA B300 SXM6 AC
          GPU UUID                                           : GPU-84199c6f-6416-3e1d-041a-5b375651e8bd
          Minor Number                                       : 0
          Platform Info
              Chassis Serial Number                          : N/A
      #{"        Module Id                                      : #{module_id}" if module_id}
          PCI
              Bus                                            : 0x#{bus_id[9, 2]}
      #{"        Bus Id                                         : #{bus_id}" if with_bus_id}

    GPU
  end

  def expect_nvidia_smi(*gpus)
    expect(lgp.sshable).to receive(:_cmd).with("nvidia-smi -q").and_return(<<~OUTPUT + gpus.join)

      ==============NVSMI LOG==============

      Driver Version                                         : 580.178.04
      CUDA Version                                           : 13.0

      Attached GPUs                                          : #{gpus.size}
    OUTPUT
  end

  def gpu_info(physical_id)
    {"physicalId" => physical_id, "uuid" => "", "pciBusId" => "", "numNvLinksAvailable" => 18, "maxNumNvLinks" => 18, "nvlinkLineRateMBps" => 50000}
  end

  def expect_fmpm_list(*partitions)
    list = {
      "version" => 16909068,
      "numPartitions" => partitions.size,
      "maxNumPartitions" => 15,
      "partitionInfo" => partitions.map { |partition_id, physical_ids|
        {"partitionId" => partition_id, "isActive" => 0, "numGpus" => physical_ids.size, "gpuInfo" => physical_ids.map { gpu_info(it) }}
      },
    }
    yield list if block_given?
    expect(lgp.sshable).to receive(:_cmd).with("/usr/bin/fmpm -l").and_return(JSON.generate(list))
  end

  def expect_fmpm(present: true)
    expect(lgp.sshable).to receive(:_cmd).with("test -x /usr/bin/fmpm && echo present || echo absent").and_return(present ? "present\n" : "absent\n")
  end

  def partitions
    GpuPartition.where(vm_host_id: vm_host.id).order(:partition_id).map {
      [it.partition_id, it.gpu_count, DB[:gpu_partitions_pci_devices].where(gpu_partition_id: it.id).join(:pci_device, id: :pci_device_id).order(:slot).select_map(:slot)]
    }
  end

  it "does nothing on hosts without fabric manager partitions" do
    expect_fmpm(present: false)
    expect { lgp.start }.to exit({"msg" => "learned GPU partitions"})
    expect(GpuPartition.count).to eq(0)
  end

  it "creates the partitions with their GPUs, matched by module ID, and updates them when run again" do
    gpus
    PciDevice.create(vm_host_id: vm_host.id, slot: "07:00.0", device_class: "0200", vendor: "15b3", device: "1023", numa_node: 0, iommu_group: 5)

    2.times do
      expect_fmpm
      expect_nvidia_smi(nvidia_smi_gpu("00000000:12:00.0", 5), nvidia_smi_gpu("00000000:F1:00.0", 1))
      expect_fmpm_list([1, [1, 5]], [8, [1]], [12, [5]])
      expect { lgp.start }.to exit({"msg" => "learned GPU partitions"})
      expect(partitions).to eq([[1, 2, ["12:00.0", "f1:00.0"]], [8, 1, ["f1:00.0"]], [12, 1, ["12:00.0"]]])
    end
  end

  it "fails if no GPU has the module ID of a GPU of a partition" do
    gpus
    expect_fmpm
    expect_nvidia_smi(nvidia_smi_gpu("00000000:12:00.0", 5))
    expect_fmpm_list([1, [5, 1]])
    expect { lgp.start }.to raise_error RuntimeError, "BUG: no GPU with module ID 1 for GPU partition 1"
    expect(GpuPartition.count).to eq(0)
  end

  it "fails if nvidia-smi does not give the module ID or PCI bus ID of a GPU" do
    gpus
    expect_fmpm
    expect_nvidia_smi(nvidia_smi_gpu("00000000:12:00.0", 5), nvidia_smi_gpu("00000000:F1:00.0", nil))
    expect { lgp.start }.to raise_error RuntimeError, "BUG: no PCI bus ID and module ID in nvidia-smi output for GPU 00000000:F1:00.0"

    expect_fmpm
    expect_nvidia_smi(nvidia_smi_gpu("00000000:12:00.0", 5, with_bus_id: false))
    expect { lgp.start }.to raise_error RuntimeError, "BUG: no PCI bus ID and module ID in nvidia-smi output for GPU 00000000:12:00.0"
  end

  it "fails if a partition does not list all of its GPUs" do
    gpus
    expect_fmpm
    expect_nvidia_smi(nvidia_smi_gpu("00000000:12:00.0", 5), nvidia_smi_gpu("00000000:F1:00.0", 1))
    expect_fmpm_list([1, [5]]) { it["partitionInfo"][0]["numGpus"] = 2 }
    expect { lgp.start }.to raise_error RuntimeError, "BUG: GPU partition 1 has 1 GPUs, expected 2"
  end
end
