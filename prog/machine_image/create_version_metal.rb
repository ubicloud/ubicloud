# frozen_string_literal: true

require "json"

class Prog::MachineImage::CreateVersionMetal < Prog::Base
  subject_is :machine_image_version
  frame_reader :source_vm_id, :destroy_source_after, :set_as_latest
  frame_accessor :archive_size_bytes

  def self.assemble(machine_image, version, source_vm, store, destroy_source_after: false, set_as_latest: true)
    fail MachineImageError, "Machine image version creation is temporarily unavailable for maintenance. Try again later."
  end

  label def archive
    register_deadline(nil, source_vm.storage_size_gib * 24) # 4 minutes per 10 GiB

    sv = source_vm.vm_storage_volumes.first
    unit_name = "archive_#{machine_image_version.ubid}"
    sshable = source_vm.vm_host.sshable

    status = sshable.d_check(unit_name)
    case status
    when "Succeeded"
      stats_json = sshable.cmd("cat :stats_path", stats_path: stats_file_path)
      stats = JSON.parse(stats_json)
      self.archive_size_bytes = stats["physical_size_bytes"]
      sshable.d_clean(unit_name)
      hop_finish
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version, stats_file_path,
        stdin: archive_params_json, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      # We'll eventually get paged if this continues. Log this to help with debugging.
      Clog.emit("Unexpected daemonizer2 status: #{status}")
      nap 60
    end
  end

  label def finish
    source_vm.vm_host.sshable.cmd("sudo rm -f :stats_path", stats_path: stats_file_path)

    machine_image_version.metal.update(
      status: "ready",
      archive_size_mib: (archive_size_bytes/1048576r).ceil,
    )
    machine_image_version.metal.create_billing_record
    if destroy_source_after
      source_vm.incr_destroy
    end
    if set_as_latest
      machine_image_version.machine_image.update(latest_version_id: machine_image_version.id)
    end
    pop "Metal machine image version is ready"
  end

  def archive_params_json
    sv = source_vm.vm_storage_volumes.first
    store = machine_image_version.metal.store

    {
      kek: sv.key_encryption_key_1.secret_key_material_hash,
      target_conf: {
        endpoint: store.endpoint,
        region: store.region,
        bucket: store.bucket,
        prefix: machine_image_version.metal.store_prefix,
        access_key_id: store.access_key,
        secret_access_key: store.secret_key,
        archive_kek: machine_image_version.metal.archive_kek.secret_key_material_hash,
      },
    }.to_json
  end

  def stats_file_path
    "/tmp/archive_stats_#{machine_image_version.ubid}.json"
  end

  def source_vm
    @source_vm ||= Vm[source_vm_id]
  end
end
