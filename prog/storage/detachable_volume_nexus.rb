# frozen_string_literal: true

class Prog::Storage::DetachableVolumeNexus < Prog::Base
  subject_is :detachable_volume

  def self.assemble(project_id:, location_id:, size_gib:, source_image:)
    DB.transaction do
      ubid = DetachableVolume.generate_ubid
      kek = StorageKeyEncryptionKey.create_random(auth_data: ubid.to_s)
      volume = DetachableVolume.create_with_id(ubid.to_uuid, project_id:, location_id:, size_gib:, source_image:,
        key_encryption_key_1_id: kek.id, wrapped_xts: DetachableVolume.wrap_xts(kek))
      Strand.create_with_id(volume, prog: "Storage::DetachableVolumeNexus", label: "wait")
      volume
    end
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    nap 30 * 24 * 60 * 60
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    if (host = detachable_volume.vm_host)
      host.sshable.cmd_json("sudo host/bin/detachable-volume delete :volume_id", volume_id: detachable_volume.ubid)
    end
    detachable_volume.destroy
    pop "detachable volume destroyed"
  end
end
