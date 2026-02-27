# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::MachineImage::Nexus < Prog::Base
  subject_is :machine_image_version

  def machine_image
    @machine_image ||= machine_image_version.machine_image
  end

  def vm
    @vm ||= machine_image_version.vm
  end

  def host
    @host ||= vm.vm_host
  end

  def vm_name
    @vm_name ||= vm.inhost_name
  end

  def boot_volume
    @boot_volume ||= vm.vm_storage_volumes.find(&:boot)
  end

  def self.assemble(machine_image_version)
    Strand.create(
      prog: "MachineImage::Nexus",
      label: "start",
      stack: [{"subject_id" => machine_image_version.id}]
    ) { it.id = machine_image_version.id }
  end

  label def start
    register_deadline(nil, 24 * 60 * 60)

    fail "VM must be stopped to create a machine image" unless vm.display_state == "stopped"
    fail "VM has no boot volume" unless boot_volume

    hop_create_kek
  end

  label def create_kek
    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    key_wrapping_key = cipher.random_key
    key_wrapping_iv = cipher.random_iv

    kek = StorageKeyEncryptionKey.create(
      algorithm: key_wrapping_algorithm,
      key: Base64.encode64(key_wrapping_key),
      init_vector: Base64.encode64(key_wrapping_iv),
      auth_data: machine_image_version.ubid
    )
    machine_image_version.update(key_encryption_key_1_id: kek.id)

    hop_archive
  end

  label def archive
    daemon_name = "archive_#{machine_image_version.ubid}"
    case host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_finish
    when "NotStarted"
      params = archive_params
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/archive-machine-image' :daemon_name", daemon_name:, stdin: params.to_json)
    when "Failed"
      stderr = begin
        host.sshable.cmd("cat var/log/:daemon_name.stderr", daemon_name:).strip
      rescue
        nil
      end
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      machine_image_version.update(state: "failed")
      Clog.emit("Failed to create machine image archive", {machine_image_archive_failed: {ubid: machine_image_version.ubid, stderr:}})
      hop_wait
    end

    nap 15
  end

  label def finish
    archive_size_bytes = calculate_archive_size
    archive_size_mib = archive_size_bytes ? (archive_size_bytes.to_f / (1024**2)).ceil : nil
    machine_image_version.update(state: "available", size_gib: boot_volume.size_gib, archive_size_mib: archive_size_mib, activated_at: Time.now)

    if machine_image.project.billable && machine_image_version.active_billing_records.empty?
      billing_rate = BillingRate.from_resource_properties("MachineImageStorage", "standard", machine_image.location.name)
      if billing_rate
        BillingRecord.create(
          project_id: machine_image.project_id,
          resource_id: machine_image_version.id,
          resource_name: machine_image.name,
          billing_rate_id: billing_rate["id"],
          amount: machine_image_version.size_gib
        )
      else
        Clog.emit("No billing rate found for machine image", {machine_image_billing_rate_missing: {ubid: machine_image_version.ubid, location: machine_image.location.name}})
      end
    end

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    if machine_image_version.state == "failed" && machine_image_version.created_at < Time.now - 3600
      hop_destroy
    end

    nap 30
  end

  label def destroy
    decr_destroy

    machine_image_version.active_billing_records.each(&:finalize)
    machine_image_version.update(state: "destroying")

    hop_destroy_record
  end

  label def destroy_record
    register_deadline(nil, 10 * 60, allow_extension: true)

    if delete_s3_objects_batch
      nap 0
    end

    kek = machine_image_version.key_encryption_key_1
    machine_image_version.update(key_encryption_key_1_id: nil)
    kek&.destroy

    mi = machine_image_version.machine_image
    machine_image_version.destroy

    if mi.deleting? && mi.versions_dataset.empty?
      mi.destroy
    end

    pop "machine image version destroyed"
  end

  private

  def archive_bin
    vbb_version = boot_volume.vhost_block_backend_version || "v0.4.0"
    "/opt/vhost-block-backend/#{vbb_version}/archive"
  end

  def device_config_path
    storage_device_name = boot_volume.storage_device&.name || "DEFAULT"
    device_dir = (storage_device_name == "DEFAULT") ? "/var/storage" : "/var/storage/devices/#{storage_device_name}"
    "#{device_dir}/#{vm_name}/#{boot_volume.disk_index}/vhost-backend.conf"
  end

  def archive_params
    creds = CloudflareR2.generate_temp_credentials(
      bucket: machine_image_version.s3_bucket,
      permission: "object-read-write",
      ttl_seconds: 86400
    )

    params = {
      "archive_bin" => archive_bin,
      "device_config" => device_config_path,
      "vm_name" => vm_name,
      "encrypt" => true,
      "s3_bucket" => machine_image_version.s3_bucket,
      "s3_prefix" => machine_image_version.s3_prefix,
      "s3_region" => "auto",
      "s3_endpoint" => machine_image_version.s3_endpoint,
      "s3_connections" => 16,
      "s3_key_id" => creds[:access_key_id],
      "s3_secret_key" => creds[:secret_access_key],
      "s3_session_token" => creds[:session_token],
      "archive_kek" => machine_image_version.key_encryption_key_1.key.strip
    }

    if boot_volume.key_encryption_key_1
      params["disk_kek"] = boot_volume.key_encryption_key_1.key.strip
    end

    params
  end

  def s3_client
    creds = CloudflareR2.generate_temp_credentials(
      bucket: machine_image_version.s3_bucket,
      permission: "object-read-write",
      ttl_seconds: 3600
    )

    Aws::S3::Client.new(
      endpoint: machine_image_version.s3_endpoint,
      access_key_id: creds[:access_key_id],
      secret_access_key: creds[:secret_access_key],
      session_token: creds[:session_token],
      region: "auto",
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required"
    )
  end

  def calculate_archive_size
    client = s3_client
    total_bytes = 0
    continuation_token = nil

    loop do
      params = {bucket: machine_image_version.s3_bucket, prefix: machine_image_version.s3_prefix}
      params[:continuation_token] = continuation_token if continuation_token

      response = client.list_objects_v2(**params)
      response.contents.each { total_bytes += it.size }

      break unless response.is_truncated
      continuation_token = response.next_continuation_token
    end

    total_bytes
  rescue => e
    Clog.emit("Failed to calculate archive size", {archive_size_error: {ubid: machine_image_version.ubid, error: e.message}})
    nil
  end

  DELETE_BATCH_SIZE = 5000

  # Deletes up to DELETE_BATCH_SIZE objects under the image prefix.
  # Returns true if more objects likely remain, false if deletion is complete.
  def delete_s3_objects_batch
    client = s3_client
    objects = []
    continuation_token = nil

    loop do
      params = {bucket: machine_image_version.s3_bucket, prefix: machine_image_version.s3_prefix}
      params[:continuation_token] = continuation_token if continuation_token

      response = client.list_objects_v2(**params)
      objects.concat(response.contents)

      break if objects.size >= DELETE_BATCH_SIZE || !response.is_truncated
      continuation_token = response.next_continuation_token
    end

    return false if objects.empty?

    objects.each_slice(1000) do |batch|
      client.delete_objects(
        bucket: machine_image_version.s3_bucket,
        delete: {objects: batch.map { {key: it.key} }}
      )
    end

    objects.size >= DELETE_BATCH_SIZE
  end
end
