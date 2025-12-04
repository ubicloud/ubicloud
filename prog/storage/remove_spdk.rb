# frozen_string_literal: true

class Prog::Storage::RemoveSpdk < Prog::Base
  subject_is :spdk_installation

  def self.assemble(spdk_installation_id)
    Strand.create(
      prog: "Storage::RemoveSpdk",
      label: "start",
      stack: [{
        "subject_id" => spdk_installation_id
      }]
    )
  end

  label def start
    vm_host = spdk_installation.vm_host

    fail "Can't remove the last storage backend from the host" if vm_host.spdk_installations.one? && vm_host.vhost_block_backends.empty?

    spdk_installation.update(allocation_weight: 0)

    hop_wait_volumes
  end

  label def wait_volumes
    nap 30 if spdk_installation.vm_storage_volumes.length > 0
    hop_remove_spdk
  end

  label def remove_spdk
    version = spdk_installation.version
    sshable = spdk_installation.vm_host.sshable
    sshable.cmd("sudo host/bin/setup-spdk remove :version", version:)

    hop_update_database
  end

  label def update_database
    vm_host = spdk_installation.vm_host
    VmHost.where(id: vm_host.id).update(
      used_hugepages_1g: Sequel[:used_hugepages_1g] - spdk_installation.hugepages
    )
    spdk_installation.destroy

    pop "SPDK installation was removed"
  end
end
