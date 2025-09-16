# frozen_string_literal: true

class Prog::Storage::RemoveVhostBlockBackend < Prog::Base
  subject_is :vhost_block_backend

  def self.assemble(vhost_block_backend_id)
    Strand.create(
      prog: "Storage::RemoveVhostBlockBackend",
      label: "start",
      stack: [{
        "subject_id" => vhost_block_backend_id
      }]
    )
  end

  label def start
    vm_host = vhost_block_backend.vm_host

    fail "Can't remove the last storage backend from the host" if vm_host.vhost_block_backends.one? && vm_host.spdk_installations.empty?

    vhost_block_backend.update(allocation_weight: 0)

    # Wait up to 4 hours for volumes to be removed before paging
    register_deadline(nil, 4 * 60 * 60)

    hop_wait_volumes
  end

  label def wait_volumes
    nap 30 if vhost_block_backend.vm_storage_volumes.length > 0

    # Now that volumes are gone, we can decrease the deadline to 5 minutes
    register_deadline(nil, 5 * 60)

    hop_remove_vhost_block_backend
  end

  label def remove_vhost_block_backend
    version = vhost_block_backend.version.shellescape
    vhost_block_backend.vm_host.sshable.cmd("sudo host/bin/setup-vhost-block-backend remove #{version}")

    vhost_block_backend.destroy

    pop "VhostBlockBackend was removed"
  end
end
