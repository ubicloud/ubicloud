# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocalVolume do
  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm(vm_host_id: vm_host.id) }
  let(:storage_device) { StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100) }

  def create_legacy_volume(disk_index:, **settings)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 10, disk_index:, **settings)
  end

  describe ".backfill" do
    it "copies settings for rows that predate local_volume" do
      volume = create_legacy_volume(disk_index: 0, track_written: true, max_read_mbytes_per_sec: 321, storage_device_id: storage_device.id)

      expect(described_class.backfill).to eq(examined: 1, copied: 1)
      expect(described_class[volume.id]).to have_attributes(
        track_written: true,
        max_read_mbytes_per_sec: 321,
        storage_device_id: storage_device.id,
      )
    end

    it "walks the table in batches" do
      3.times { create_legacy_volume(disk_index: it) }

      expect(described_class.backfill(batch_size: 1)).to eq(examined: 3, copied: 3)
      expect(described_class.count).to eq(3)
    end

    it "leaves rows that were already copied alone" do
      volume = create_legacy_volume(disk_index: 0, track_written: true)
      described_class.create_with_id(volume, track_written: false)

      expect(described_class.backfill).to eq(examined: 1, copied: 0)
      expect(described_class[volume.id].track_written).to be false
    end

    it "advances past batches whose rows were already copied" do
      volumes = Array.new(3) { create_legacy_volume(disk_index: it, max_read_mbytes_per_sec: 100) }
      middle = volumes.sort_by(&:id)[1]
      described_class.create_with_id(middle, max_read_mbytes_per_sec: 999)

      expect(described_class.backfill(batch_size: 1)).to eq(examined: 3, copied: 2)
      expect(described_class.count).to eq(3)
      expect(described_class[middle.id].max_read_mbytes_per_sec).to eq(999)
      (volumes - [middle]).each do |volume|
        expect(described_class[volume.id].max_read_mbytes_per_sec).to eq(100)
      end
    end

    it "stops when the last batch exactly fills the batch size" do
      2.times { create_legacy_volume(disk_index: it) }

      expect(described_class.backfill(batch_size: 2)).to eq(examined: 2, copied: 2)
      expect(described_class.count).to eq(2)
    end

    it "copies values as they stand when the batch is inserted" do
      volume = create_legacy_volume(disk_index: 0, max_read_mbytes_per_sec: 100)
      volume.this.update(max_read_mbytes_per_sec: 200)

      described_class.backfill

      expect(described_class[volume.id].max_read_mbytes_per_sec).to eq(200)
    end

    it "leaves later writes through an already-loaded volume intact" do
      volume = create_legacy_volume(disk_index: 0, max_read_mbytes_per_sec: 100)
      volume.update_local_settings(max_read_mbytes_per_sec: 200)

      described_class.backfill

      volume.update_local_settings(max_read_mbytes_per_sec: 300)
      expect(volume.reload.max_read_mbytes_per_sec).to eq(300)
      expect(described_class[volume.id].max_read_mbytes_per_sec).to eq(300)
    end

    it "does nothing when there is nothing to copy" do
      expect(described_class.backfill).to eq(examined: 0, copied: 0)
    end
  end
end
