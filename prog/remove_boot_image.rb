# frozen_string_literal: true

class Prog::RemoveBootImage < Prog::Base
  subject_is :boot_image

  label def start
    boot_image.update(activated_at: nil)
    hop_wait_volumes
  end

  label def wait_volumes
    nap 30 if boot_image.vm_storage_volumes.count > 0
    hop_remove
  end

  label def remove
    boot_image.vm_host.sshable.cmd("sudo rm -rf :path", path: boot_image.path)

    hop_update_database
  end

  label def update_database
    StorageDevice.where(vm_host_id: boot_image.vm_host.id, name: "DEFAULT").update(
      available_storage_gib: Sequel[:available_storage_gib] + boot_image.size_gib
    )
    boot_image.destroy
    pop "Boot image was removed."
  end
end
