# frozen_string_literal: true

require "json"

class Prog::MachineImage::CreateVersionMetalFromUrl < Prog::Base
  subject_is :machine_image_version
  frame_reader :url, :sha256sum, :vm_host_id, :vhost_block_backend_version, :set_as_latest
  frame_accessor :physical_size_bytes, :logical_size_bytes

  def self.assemble(machine_image, version, url, sha256sum, store, set_as_latest: true)
    fail MachineImageError, "Machine image version creation is temporarily unavailable for maintenance. Try again later."
  end

  label def archive
    register_deadline(nil, 3600)

    unit_name = "archive_#{machine_image_version.ubid}"
    sshable = vm_host.sshable

    status = sshable.d_check(unit_name)
    case status
    when "Succeeded"
      stats_json = sshable.cmd("cat :stats_path", stats_path: stats_file_path)
      stats = JSON.parse(stats_json)
      self.physical_size_bytes = stats["physical_size_bytes"]
      self.logical_size_bytes = stats["logical_size_bytes"]
      sshable.d_clean(unit_name)
      hop_finish
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-url", url, sha256sum, vhost_block_backend_version, stats_file_path,
        stdin: archive_params_json, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit("Unexpected daemonizer2 status: #{status}")
      nap 60
    end
  end

  label def finish
    vm_host.sshable.cmd("sudo rm -f :stats_path", stats_path: stats_file_path)

    machine_image_version.metal.update(
      status: "ready",
      archive_size_mib: (physical_size_bytes/1048576r).ceil,
    )
    machine_image_version.metal.create_billing_record

    machine_image_version.update(actual_size_mib: (logical_size_bytes/1048576r).ceil)

    if set_as_latest
      machine_image_version.machine_image.update(latest_version_id: machine_image_version.id)
    end

    pop "Metal machine image version is ready"
  end

  def archive_params_json
    store = machine_image_version.metal.store

    {
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
    mi_version = machine_image_version.metal.machine_image_version
    "/tmp/archive_stats_#{mi_version.ubid}.json"
  end

  def vm_host
    @vm_host ||= VmHost[vm_host_id]
  end
end
