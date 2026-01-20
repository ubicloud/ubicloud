# frozen_string_literal: true

class Prog::Vm::Storage::PersistentStorageVolumeNexus < Prog::Base
  subject_is :persistent_storage_volume

  def self.assemble(name, size_gib)
    DB.transaction do
      persistent_storage_volume = PersistentStorageVolume.create(
        name:,
        size_gib:
      )

      Strand.create_with_id(
        persistent_storage_volume,
        prog: "Vm::Storage::PersistentStorageVolumeNexus",
        label: "wait"
      )
    end
  end

  label def wait
    when_attach_set? do
      hop_start_attach
    end
    nap 60 * 60
  end

  label def start_attach
    decr_attach
  end
end
