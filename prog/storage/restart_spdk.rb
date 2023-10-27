# frozen_string_literal: true

class Prog::Storage::RestartSpdk < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    # We will send volume information to `storage-ctl`. Temporarily don't accept
    # new VMs on this host to make we don't miss any volumes in the payload
    # because of concurrency.
    #
    # Concurrent VM deletions might still happen, and `storage-ctl` should
    # handle the cases where a volume has been deleted.
    raise "Host not in accepting mode" if vm_host.allocation_state != "accepting"
    vm_host.update(allocation_state: "updating")
    hop_wait_until_vms_idle
  end

  label def wait_until_vms_idle
    nap 30 if vms_not_waiting != 0

    hop_restart
  end

  label def restart
    params_json = JSON.generate({
      volumes: storage_volumes_dataset.map { |s| s.params_hash },
      secrets: storage_secrets_hash
    })

    # We only have 60 seconds (hard-coded in cloud-hypervisor's code) after
    # stopping SPDK to start all volumes. So, do these 3 commands back-to-back
    # instead of breaking them into multiple state machine steps.
    sshable.cmd("sudo systemctl stop spdk")
    sshable.cmd("sudo systemctl start spdk")
    sshable.cmd("sudo host/bin/storage-ctl start-volumes", stdin: params_json)

    vm_host.update(allocation_state: "accepting")
    pop "SPDK was restarted"
  end

  def storage_volumes_dataset
    @storage_volumes ||=
      VmStorageVolume
        .where(vm_id: vm_host.vms_dataset.select(:id))
  end

  def storage_secrets_hash
    @storage_secrets_hash ||=
      VmStorageVolume.storage_secrets_hash(storage_volumes_dataset)
  end

  def vms_not_waiting
    Strand.where(id: vm_host.vms_dataset.select(:id))
      .exclude(label: "wait")
      .count
  end
end
