# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::MachineImage::RegisterDistroImage < Prog::Base
  subject_is :machine_image_version

  def machine_image
    @machine_image ||= machine_image_version.machine_image
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def url
    @url ||= frame.fetch("url")
  end

  def sha256
    @sha256 ||= frame.fetch("sha256")
  end

  def work_dir
    "/var/storage/temp/register-distro-#{machine_image_version.ubid}"
  end

  def vbb_version
    "v0.4.0"
  end

  def archive_bin
    "/opt/vhost-block-backend/#{vbb_version}/archive"
  end

  def init_metadata_bin
    "/opt/vhost-block-backend/#{vbb_version}/init-metadata"
  end

  def self.assemble(machine_image_version, vm_host_id:, url:, sha256:)
    Strand.create(
      prog: "MachineImage::RegisterDistroImage",
      label: "start",
      stack: [{"subject_id" => machine_image_version.id, "vm_host_id" => vm_host_id, "url" => url, "sha256" => sha256}]
    ) { it.id = machine_image_version.id }
  end

  label def start
    register_deadline(nil, 24 * 60 * 60)

    fail "No host available for distro image registration" unless vm_host

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

    hop_register
  end

  label def register
    daemon_name = "register_distro_#{machine_image_version.ubid}"
    case vm_host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      stdout = vm_host.sshable.cmd("cat var/log/:daemon_name.stdout", daemon_name:).strip
      vm_host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)

      size_gib = stdout.to_i
      size_gib = 1 if size_gib < 1
      machine_image_version.update(size_gib:, state: "available", activated_at: Time.now)

      hop_wait
    when "NotStarted"
      params = register_params
      vm_host.sshable.cmd(
        "common/bin/daemonizer 'sudo host/bin/register-distro-image' :daemon_name",
        daemon_name:, stdin: params.to_json
      )
    when "Failed"
      stderr = begin
        vm_host.sshable.cmd("cat var/log/:daemon_name.stderr", daemon_name:).strip
      rescue
        nil
      end
      vm_host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      machine_image_version.update(state: "failed")
      Clog.emit("Failed to register distro image", {distro_image_register_failed: {ubid: machine_image_version.ubid, stderr:}})
      hop_wait
    end

    nap 15
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
    register_deadline(nil, 10 * 60)
    decr_destroy

    machine_image_version.active_billing_records.each(&:finalize)
    machine_image_version.update(state: "destroying")

    hop_destroy_record
  end

  label def destroy_record
    delete_s3_objects

    kek = machine_image_version.key_encryption_key_1
    machine_image_version.update(key_encryption_key_1_id: nil)
    kek&.destroy

    machine_image_version.destroy
    pop "distro image version destroyed"
  end

  private

  def register_params
    creds = CloudflareR2.generate_temp_credentials(
      bucket: machine_image_version.s3_bucket,
      permission: "object-read-write",
      ttl_seconds: 86400
    )

    {
      "url" => url,
      "sha256" => sha256,
      "work_dir" => work_dir,
      "archive_bin" => archive_bin,
      "init_metadata_bin" => init_metadata_bin,
      "secrets_id" => "register-distro-#{machine_image_version.ubid}",
      "s3_bucket" => machine_image_version.s3_bucket,
      "s3_prefix" => machine_image_version.s3_prefix,
      "s3_endpoint" => machine_image_version.s3_endpoint,
      "s3_key_id" => creds[:access_key_id],
      "s3_secret_key" => creds[:secret_access_key],
      "s3_session_token" => creds[:session_token],
      "archive_kek" => machine_image_version.key_encryption_key_1.key
    }
  end

  def delete_s3_objects
    creds = CloudflareR2.generate_temp_credentials(
      bucket: machine_image_version.s3_bucket,
      permission: "object-read-write",
      ttl_seconds: 3600
    )

    client = Aws::S3::Client.new(
      endpoint: machine_image_version.s3_endpoint,
      access_key_id: creds[:access_key_id],
      secret_access_key: creds[:secret_access_key],
      session_token: creds[:session_token],
      region: "auto",
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required"
    )

    objects = []
    response = client.list_objects_v2(bucket: machine_image_version.s3_bucket, prefix: machine_image_version.s3_prefix)
    objects.concat(response.contents)
    while response.is_truncated
      response = client.list_objects_v2(
        bucket: machine_image_version.s3_bucket,
        prefix: machine_image_version.s3_prefix,
        continuation_token: response.next_continuation_token
      )
      objects.concat(response.contents)
    end

    objects.each_slice(1000) do |batch|
      client.delete_objects(
        bucket: machine_image_version.s3_bucket,
        delete: {objects: batch.map { {key: it.key} }}
      )
    end
  end

  def toml_str(value)
    "\"#{value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
  end
end
