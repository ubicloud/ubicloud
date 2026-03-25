# frozen_string_literal: true

require "aws-sdk-s3"
require "json"

class Prog::MachineImage::CreateVersionMetalFromUrl < Prog::Base
  subject_is :machine_image_version_metal

  def self.assemble(machine_image_version, url, sha256, store, vm_host, set_as_latest: true)
    mi = machine_image_version.machine_image
    version = machine_image_version.version
    archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{machine_image_version.ubid}_#{version}")

    mi_version_metal = MachineImageVersionMetal.create_with_id(
      machine_image_version,
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix: "#{mi.project.ubid}/#{mi.ubid}/#{version}"
    )

    Strand.create_with_id(
      mi_version_metal,
      prog: "MachineImage::CreateVersionMetalFromUrl",
      label: "archive",
      stack: [{
        "subject_id" => mi_version_metal.id,
        "vm_host_id" => vm_host.id,
        "url" => url,
        "sha256" => sha256,
        "set_as_latest" => set_as_latest
      }]
    )
  end

  label def archive
    register_deadline(nil, 24 * 60 * 60)

    mi_version = machine_image_version_metal.machine_image_version
    unit_name = "archive_url_#{mi_version.ubid}"
    sshable = vm_host.sshable

    status = sshable.d_check(unit_name)
    case status
    when "Succeeded"
      hop_read_result
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-url", frame["url"], frame["sha256"], "v0.4.0",
        stdin: archive_params_json, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit("Unexpected daemonizer2 status: #{status}")
      nap 60
    end
  end

  label def read_result
    mi_version = machine_image_version_metal.machine_image_version
    unit_name = "archive_url_#{mi_version.ubid}"
    sshable = vm_host.sshable

    stdout = sshable.cmd("sudo journalctl -u :unit_name.service --output=cat --no-pager | grep image_size_mib", unit_name:)
    result = JSON.parse(stdout.strip)
    current_frame = strand.stack.first
    current_frame["image_size_mib"] = result["image_size_mib"]
    strand.modified!(:stack)
    strand.save_changes

    sshable.d_clean(unit_name)
    hop_finish
  end

  label def finish
    machine_image_version_metal.update(
      enabled: true,
      archive_size_mib: (archive_size_bytes/1048576r).ceil
    )

    miv = machine_image_version_metal.machine_image_version
    miv.update(actual_size_mib: frame["image_size_mib"])

    if frame["set_as_latest"]
      miv.machine_image.update(latest_version_id: miv.id)
    end

    pop "machine image version created from url"
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def archive_params_json
    store = machine_image_version_metal.store

    target = {
      endpoint: store.endpoint,
      region: store.region,
      bucket: store.bucket,
      prefix: machine_image_version_metal.store_prefix,
      access_key_id: store.access_key,
      secret_access_key: store.secret_key,
      archive_kek: machine_image_version_metal.archive_kek.secret_key_material_hash
    }

    {target_conf: target}.to_json
  end

  def archive_size_bytes
    store = machine_image_version_metal.store

    s3 = Aws::S3::Client.new(
      region: store.region,
      endpoint: store.endpoint,
      access_key_id: store.access_key,
      secret_access_key: store.secret_key
    )

    total = 0
    s3.list_objects_v2(bucket: store.bucket, prefix: machine_image_version_metal.store_prefix).each_page do |page|
      total += page.contents.sum(&:size)
    end
    total
  end
end
