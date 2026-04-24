# frozen_string_literal: true

require "json"

class Prog::MachineImage::CreateVersionMetal < Prog::Base
  subject_is :machine_image_version

  def self.assemble(machine_image, version, source_vm, store, destroy_source_after: false, set_as_latest: true)
    fail MachineImageError.new("Source VM arch (#{source_vm.arch}) does not match machine image arch (#{machine_image.arch})") unless source_vm.arch == machine_image.arch
    fail MachineImageError.new("Source VM must be a metal VM") unless source_vm.vm_host
    fail MachineImageError.new("Source VM must have only one storage volume") unless source_vm.vm_storage_volumes.count == 1
    fail MachineImageError.new("Source VM must be stopped") unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail MachineImageError.new("Source VM's vhost block backend must support archive") unless sv.vhost_block_backend&.supports_archive?
    fail MachineImageError.new("Source VM's storage volume must be encrypted") unless sv.key_encryption_key_1

    DB.transaction do
      miv = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version:,
        actual_size_mib: source_vm.storage_size_gib * 1024,
      )
      archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{miv.ubid}_#{version}")
      MachineImageVersionMetal.create_with_id(miv,
        enabled: false,
        archive_kek_id: archive_kek.id,
        store_id: store.id,
        store_prefix: "#{machine_image.project.ubid}/#{machine_image.ubid}/#{version}")

      Strand.create_with_id(miv,
        prog: "MachineImage::CreateVersionMetal",
        label: "archive",
        stack: [{
          "source_vm_id" => source_vm.id,
          "destroy_source_after" => destroy_source_after,
          "set_as_latest" => set_as_latest,
        }])
    end
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
      update_stack("archive_size_bytes" => stats["physical_size_bytes"])
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
      enabled: true,
      archive_size_mib: (frame["archive_size_bytes"]/1048576r).ceil,
    )
    if frame["destroy_source_after"]
      source_vm.incr_destroy
    end
    if frame["set_as_latest"]
      machine_image_version.machine_image.update(latest_version_id: machine_image_version.id)
    end
    pop "Metal machine image version is created and enabled"
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
    @source_vm ||= Vm[frame["source_vm_id"]]
  end
end
