# frozen_string_literal: true

require "aws-sdk-s3"
require "json"

class Prog::MachineImage::CreateVersion < Prog::Base
  subject_is :machine_image_version

  def self.assemble(machine_image, version, source_vm, destroy_source_after: false)
    fail "source vm must have only one storage volume" unless source_vm.vm_storage_volumes.count == 1
    fail "source vm must be stopped" unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail "source vm's vhost block backend must support archive" unless sv.vhost_block_backend&.supports_archive?

    key_encryption_key = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{machine_image.ubid}_#{version}")
    s3_prefix = "#{machine_image.project.ubid}/#{machine_image.ubid}/#{version}"

    mi_version = MachineImageVersion.create(
      machine_image_id: machine_image.id,
      version:,
      enabled: false,
      actual_size_mib: sv.size_gib * 1024,
      key_encryption_key_id: key_encryption_key.id,
      s3_endpoint: r2_endpoint_url(machine_image.location.name),
      s3_bucket: Config.machine_image_r2_bucket,
      s3_prefix:
    )

    Strand.create(
      prog: "MachineImage::CreateVersion",
      label: "archive",
      stack: [{
        "subject_id" => mi_version.id,
        "source_vm_id" => source_vm.id,
        "destroy_source_after" => destroy_source_after
      }]
    ) { it.id = mi_version.id }
  end

  def self.r2_endpoint_url(location)
    if location.start_with?("us-")
      "https://#{Config.machine_image_r2_account_id}.r2.cloudflarestorage.com"
    else
      "https://#{Config.machine_image_r2_account_id}.eu.r2.cloudflarestorage.com"
    end
  end

  label def archive
    register_deadline(nil, 15 * 60)

    daemon_name = "archive_#{machine_image_version.ubid}"
    host = Vm[frame["source_vm_id"]].vm_host
    case host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_finish
    when "Failed", "NotStarted"
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/archive-storage-volume' :daemon_name", daemon_name:, stdin: archive_params_json)
    end

    nap 30
  end

  label def finish
    machine_image_version.machine_image.update(
      latest_version_id: machine_image_version.id
    )
    machine_image_version.update(
      enabled: true,
      archive_size_mib: archive_size_bytes / 1024 / 1024
    )
    if frame["destroy_source_after"]
      source_vm = Vm[frame["source_vm_id"]]
      source_vm.incr_destroy
    end
    pop "Machine image version #{machine_image_version.version} is created and enabled"
  end

  def archive_params_json
    # We use temporary credentials for operations done in the VM hosts.
    cloudflare_client = CloudflareClient.new(Config.machine_image_r2_api_token)
    creds = cloudflare_client.generate_temp_credentials(
      account_id: Config.machine_image_r2_account_id,
      parent_access_key_id: Config.machine_image_r2_access_key,
      bucket: Config.machine_image_r2_bucket,
      permission: "object-read-write",
      ttl_seconds: 86400
    )

    source_vm = Vm[frame["source_vm_id"]]
    sv = source_vm.vm_storage_volumes.first

    {
      vm_name: source_vm.inhost_name,
      device: sv.storage_device.name,
      disk_index: sv.disk_index,
      vhost_block_backend_version: sv.vhost_block_backend.version,
      kek: sv.key_encryption_key_1.secret_key_material_hash,
      target_conf: {
        endpoint: machine_image_version.s3_endpoint,
        region: "auto",
        bucket: machine_image_version.s3_bucket,
        prefix: machine_image_version.s3_prefix,
        access_key_id: creds[:access_key_id],
        secret_access_key: creds[:secret_access_key],
        session_token: creds[:session_token],
        archive_kek: machine_image_version.key_encryption_key.secret_key_material_hash
      }
    }.to_json
  end

  def archive_size_bytes
    s3 = Aws::S3::Client.new(
      region: "auto",
      endpoint: machine_image_version.s3_endpoint,
      access_key_id: Config.machine_image_r2_access_key,
      secret_access_key: Config.machine_image_r2_secret_key
    )

    total = 0
    s3.list_objects_v2(bucket: machine_image_version.s3_bucket, prefix: machine_image_version.s3_prefix).each do |page|
      total += page.contents.sum(&:size)
    end
    total
  end
end
