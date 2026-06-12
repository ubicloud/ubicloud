# frozen_string_literal: true

require "json"

class Prog::MachineImage::CreateVersionMetal < Prog::Base
  subject_is :machine_image_version

  frame_reader :source_vm_id, :destroy_source_after,
    :url, :sha256sum, :vm_host_id, :vhost_block_backend_version,
    :set_as_latest
  frame_accessor :physical_size_bytes, :logical_size_bytes

  def self.assemble_from_vm(machine_image, version, source_vm, store,
    destroy_source_after: false, set_as_latest: true)
    fail MachineImageError, "Source VM arch (#{source_vm.arch}) does not match machine image arch (#{machine_image.arch})" unless source_vm.arch == machine_image.arch
    fail MachineImageError, "Source VM must be a metal VM" unless source_vm.vm_host
    fail MachineImageError, "Source VM must have only one storage volume" unless source_vm.vm_storage_volumes.count == 1
    fail MachineImageError, "Source VM must be stopped" unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail MachineImageError, "Source VM's storage volume doesn't support machine images" unless sv.track_written
    fail MachineImageError, "Source VM's storage volume must be encrypted" unless sv.key_encryption_key_1
    fail MachineImageError, "Source VM's storage volume is larger than #{Config.machine_image_max_size_gib} GiB" if sv.size_gib > Config.machine_image_max_size_gib

    DB.transaction do
      miv = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version:,
        actual_size_mib: nil,
      )
      archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{miv.ubid}_#{miv.version}")
      MachineImageVersionMetal.create_with_id(miv,
        status: "creating",
        archive_kek_id: archive_kek.id,
        store_id: store.id,
        store_prefix: "#{machine_image.project.ubid}/#{machine_image.ubid}/#{miv.version}")

      Strand.create_with_id(miv,
        prog: "MachineImage::CreateVersionMetal",
        label: "archive_from_vm",
        stack: [{
          "source_vm_id" => source_vm.id,
          "destroy_source_after" => destroy_source_after,
          "set_as_latest" => set_as_latest,
        }])
    end
  end

  def self.assemble_from_url(machine_image, version, url, sha256sum, store, set_as_latest: true)
    vbb = VhostBlockBackend
      .where(vm_host_id: VmHost.where(location_id: machine_image.location_id).select(:id))
      .where { version_code >= VhostBlockBackend::MIN_ARCHIVE_SUPPORT_VERSION }
      .order { random.function }
      .first

    fail "no vm host with archive support found in location" unless vbb

    DB.transaction do
      miv = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version:,
        actual_size_mib: nil,
      )
      archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{miv.ubid}_#{version}")
      MachineImageVersionMetal.create_with_id(miv,
        status: "creating",
        archive_kek_id: archive_kek.id,
        store_id: store.id,
        store_prefix: "#{machine_image.project.ubid}/#{machine_image.ubid}/#{version}")

      Strand.create_with_id(miv,
        prog: "MachineImage::CreateVersionMetal",
        label: "archive_from_url",
        stack: [{
          "url" => url,
          "sha256sum" => sha256sum,
          "vm_host_id" => vbb.vm_host_id,
          "vhost_block_backend_version" => vbb.version,
          "set_as_latest" => set_as_latest,
        }])
    end
  end

  label def archive_from_vm
    register_deadline(nil, source_vm.storage_size_gib * 24) # 4 minutes per 10 GiB

    sv = source_vm.vm_storage_volumes.first
    unit_name = "archive_#{machine_image_version.ubid}"
    sshable = vm_host.sshable

    case sshable.d_check(unit_name)
    when "Succeeded"
      capture_stats(sshable)
      sshable.d_clean(unit_name)
      hop_finish
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version, stats_file_path,
        stdin: archive_params_json_for_vm, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      # We'll eventually get paged if this continues. Log this to help with debugging.
      Clog.emit("Unexpected daemonizer2 status: #{sshable.d_check(unit_name)}")
      nap 60
    end
  end

  label def archive_from_url
    register_deadline(nil, 3600)

    unit_name = "archive_#{machine_image_version.ubid}"
    sshable = vm_host.sshable

    case sshable.d_check(unit_name)
    when "Succeeded"
      capture_stats(sshable)
      sshable.d_clean(unit_name)
      hop_finish
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-url", url, sha256sum, vhost_block_backend_version, stats_file_path,
        stdin: archive_params_json_for_url, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit("Unexpected daemonizer2 status: #{sshable.d_check(unit_name)}")
      nap 60
    end
  end

  label def finish
    vm_host.sshable.cmd("sudo rm -f :stats_path", stats_path: stats_file_path)

    machine_image_version.metal.update(
      status: "ready",
      archive_size_mib: (physical_size_bytes/1048576r).ceil,
    )
    machine_image_version.update(actual_size_mib: (logical_size_bytes/1048576r).ceil)
    machine_image_version.metal.create_billing_record

    if destroy_source_after && source_vm
      source_vm.incr_destroy
    end
    if set_as_latest
      machine_image_version.machine_image.update(latest_version_id: machine_image_version.id)
    end

    pop "Metal machine image version is ready"
  end

  def source_vm
    return @source_vm if defined?(@source_vm)
    @source_vm = source_vm_id ? Vm[source_vm_id] : nil
  end

  def vm_host
    @vm_host ||= source_vm ? source_vm.vm_host : VmHost[vm_host_id]
  end

  def stats_file_path
    "/tmp/archive_stats_#{machine_image_version.ubid}.json"
  end

  private

  def capture_stats(sshable)
    stats = JSON.parse(sshable.cmd("cat :stats_path", stats_path: stats_file_path))
    self.physical_size_bytes = stats["physical_size_bytes"]
    self.logical_size_bytes = stats["logical_size_bytes"]
  end

  def archive_params_json_for_vm
    sv = source_vm.vm_storage_volumes.first
    {
      kek: sv.key_encryption_key_1.secret_key_material_hash,
      target_conf:,
    }.to_json
  end

  def archive_params_json_for_url
    {target_conf:}.to_json
  end

  def target_conf
    store = machine_image_version.metal.store
    {
      endpoint: store.endpoint,
      region: store.region,
      bucket: store.bucket,
      prefix: machine_image_version.metal.store_prefix,
      access_key_id: store.access_key,
      secret_access_key: store.secret_key,
      archive_kek: machine_image_version.metal.archive_kek.secret_key_material_hash,
    }
  end
end
