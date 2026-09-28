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

    when_catch_up_set? do
      decr_catch_up
      hop_wait_catch_up
    end

    nap 30 * 24 * 60 * 60
  end

  label def wait_catch_up
    register_deadline("wait", 60 * 60)
    host = detachable_volume.vm_host
    status = host.sshable.cmd_json("sudo host/bin/detachable-volume status :volume_id", volume_id: detachable_volume.ubid)
    nap 5 unless status["caught_up"]

    if (server = detachable_volume.remote_storage_server)
      host.sshable.cmd_json("sudo host/bin/detachable-volume drop-source :volume_id", volume_id: detachable_volume.ubid)
      server.incr_destroy
    end
    hop_wait
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    nap 5 if detachable_volume.key_encryption_key_2_id
    decr_destroy

    detachable_volume.remote_storage_server&.incr_destroy
    hop_wait_remote_storage_server_destroyed
  end

  label def wait_remote_storage_server_destroyed
    nap 5 unless detachable_volume.remote_storage_server_dataset.empty?
    hop_delete_from_host
  end

  label def delete_from_host
    if (host = detachable_volume.vm_host)
      host.sshable.cmd_json("sudo host/bin/detachable-volume delete :volume_id", volume_id: detachable_volume.ubid)
    end
    detachable_volume.destroy
    pop "detachable volume destroyed"
  end
end
