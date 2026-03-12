# frozen_string_literal: true

require "aws-sdk-s3"
require "json"

class Prog::MachineImage::CreateVersionMetal < Prog::Base
  subject_is :machine_image_version_metal

  def self.assemble(machine_image_version, source_vm, store, destroy_source_after: false)
    fail "source vm must be a metal vm" unless source_vm.vm_host
    fail "source vm must have only one storage volume" unless source_vm.vm_storage_volumes.count == 1
    fail "source vm must be stopped" unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail "source vm's vhost block backend must support archive" unless sv.vhost_block_backend&.supports_archive?

    mi = machine_image_version.machine_image
    version = machine_image_version.version
    store_prefix = "#{mi.project.ubid}/#{mi.ubid}/#{version}"

    archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{machine_image_version.ubid}_#{version}")

    mi_version_metal = MachineImageVersionMetal.create(
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix:
    ) { it.id = machine_image_version.id }

    Strand.create(
      prog: "MachineImage::CreateVersionMetal",
      label: "archive",
      stack: [{
        "subject_id" => mi_version_metal.id,
        "source_vm_id" => source_vm.id,
        "destroy_source_after" => destroy_source_after
      }]
    ) { it.id = mi_version_metal.id }
  end

  label def archive
    register_deadline(nil, 15 * 60)

    source_vm = Vm[frame["source_vm_id"]]
    sv = source_vm.vm_storage_volumes.first
    mi_version = machine_image_version_metal.machine_image_version

    daemon_name = "archive_#{mi_version.ubid}"
    host = source_vm.vm_host
    case host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_finish
    when "Failed", "NotStarted"
      d_command = NetSsh.command(
        "sudo host/bin/archive-storage-volume :vm_name :device :disk_index :vhost_block_backend_version",
        vm_name: source_vm.inhost_name,
        device: sv.storage_device.name,
        disk_index: sv.disk_index,
        vhost_block_backend_version: sv.vhost_block_backend.version
      )
      host.sshable.cmd("common/bin/daemonizer :d_command :daemon_name", d_command:, daemon_name:, stdin: archive_params_json)
    end

    nap 30
  end

  label def finish
    machine_image_version_metal.update(
      enabled: true,
      archive_size_mib: archive_size_bytes / 1024 / 1024
    )
    if frame["destroy_source_after"]
      source_vm = Vm[frame["source_vm_id"]]
      source_vm.incr_destroy
    end
    pop "Metal machine image version is created and enabled"
  end

  def archive_params_json
    source_vm = Vm[frame["source_vm_id"]]
    sv = source_vm.vm_storage_volumes.first
    store = machine_image_version_metal.store

    {
      kek: sv.key_encryption_key_1.secret_key_material_hash,
      target_conf: {
        endpoint: store.endpoint,
        region: store.region,
        bucket: store.bucket,
        prefix: machine_image_version_metal.store_prefix,
        access_key_id: store.access_key,
        secret_access_key: store.secret_key,
        archive_kek: machine_image_version_metal.archive_kek.secret_key_material_hash
      }
    }.to_json
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
    s3.list_objects_v2(bucket: store.bucket, prefix: machine_image_version_metal.store_prefix).each do |page|
      total += page.contents.sum(&:size)
    end
    total
  end
end
