# frozen_string_literal: true

class Prog::LearnPci < Prog::Base
  subject_is :sshable, :vm_host

  REQUIRED_KEYS = ["Slot", "Class", "Vendor", "Device"]
  PciDeviceRecord = Struct.new(:slot, :device_class, :vendor, :device, :numa_node, :iommu_group) do
    def self.parse_all(lspci_str)
      out = []
      lspci_str.strip.split(/^\n+/).each do |dev_str|
        dev_h = dev_str.split("\n").map { |e| e.split(":\t") }.to_h
        fail "BUG: lspci parse failed" unless REQUIRED_KEYS.all? { |s| dev_h.key? s }
        next unless dev_h.key? "IOMMUGroup"
        out << PciDeviceRecord.new(dev_h["Slot"], dev_h["Class"], dev_h["Vendor"], dev_h["Device"], dev_h["NUMANode"], dev_h["IOMMUGroup"])
      end
      out.freeze
    end
  end

  def make_model_instances
    PciDeviceRecord.parse_all(sshable.cmd("/usr/bin/lspci -vnmm -d 10de::")).map do |rec|
      PciDevice.new(
        vm_host_id: vm_host.id,
        slot: rec.slot,
        device_class: rec.device_class,
        vendor: rec.vendor,
        device: rec.device,
        numa_node: rec.numa_node,
        iommu_group: rec.iommu_group
      )
    end
  end

  label def start
    make_model_instances.each do |pci|
      pci.skip_auto_validations(:unique) do
        pci.insert_conflict(target: [:vm_host_id, :slot],
          update: {
            device_class: Sequel[:excluded][:device_class],
            vendor: Sequel[:excluded][:vendor],
            device: Sequel[:excluded][:device],
            numa_node: Sequel[:excluded][:numa_node],
            iommu_group: Sequel[:excluded][:iommu_group]
          }).save_changes
      end
    end

    pop("created PciDevice records")
  end
end
