# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::MachineImage::RegisterDistroImage < Prog::Base
  subject_is :machine_image

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
    "/var/storage/temp/register-distro-#{machine_image.ubid}"
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

  label def start
    register_deadline(nil, 24 * 60 * 60)

    unless vm_host
      fail "No host available for distro image registration"
    end

    hop_register
  end

  label def register
    daemon_name = "register_distro_#{machine_image.ubid}"
    case vm_host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      stdout = vm_host.sshable.cmd("cat var/log/:daemon_name.stdout", daemon_name:).strip
      vm_host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)

      size_gib = stdout.to_i
      size_gib = 1 if size_gib < 1
      machine_image.update(size_gib:, state: "available")

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
      machine_image.update(state: "failed")
      Clog.emit("Failed to register distro image", {distro_image_register_failed: {ubid: machine_image.ubid, stderr:}})
      hop_wait
    end

    nap 15
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end
    nap 30
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    machine_image.active_billing_records.each(&:finalize)
    machine_image.update(state: "destroying")
    delete_s3_objects

    machine_image.destroy
    pop "distro image destroyed"
  end

  private

  def target_config_toml
    secrets_path = "#{work_dir}/secrets"
    lines = []
    lines << "[target]"
    lines << "storage = \"s3\""
    lines << "bucket = #{toml_str(machine_image.s3_bucket)}"
    lines << "prefix = #{toml_str(machine_image.s3_prefix)}"
    lines << "region = \"auto\""
    lines << "endpoint = #{toml_str(machine_image.s3_endpoint)}"
    lines << "connections = 16"
    lines << "access_key_id.ref = \"s3-key-id\""
    lines << "secret_access_key.ref = \"s3-secret-key\""
    lines << ""
    lines << "[secrets.s3-key-id]"
    lines << "source.file = \"#{secrets_path}/s3-key-id.pipe\""
    lines << ""
    lines << "[secrets.s3-secret-key]"
    lines << "source.file = \"#{secrets_path}/s3-secret-key.pipe\""
    lines.join("\n") + "\n"
  end

  def register_params
    {
      "url" => url,
      "sha256" => sha256,
      "work_dir" => work_dir,
      "archive_bin" => archive_bin,
      "init_metadata_bin" => init_metadata_bin,
      "target_config_content" => target_config_toml,
      "s3_key_id" => Config.machine_image_archive_access_key,
      "s3_secret_key" => Config.machine_image_archive_secret_key
    }
  end

  def delete_s3_objects
    client = Aws::S3::Client.new(
      endpoint: machine_image.s3_endpoint,
      access_key_id: Config.machine_image_archive_access_key,
      secret_access_key: Config.machine_image_archive_secret_key,
      region: "auto",
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required"
    )

    objects = []
    response = client.list_objects_v2(bucket: machine_image.s3_bucket, prefix: machine_image.s3_prefix)
    objects.concat(response.contents)
    while response.is_truncated
      response = client.list_objects_v2(
        bucket: machine_image.s3_bucket,
        prefix: machine_image.s3_prefix,
        continuation_token: response.next_continuation_token
      )
      objects.concat(response.contents)
    end

    objects.each_slice(1000) do |batch|
      client.delete_objects(
        bucket: machine_image.s3_bucket,
        delete: {objects: batch.map { {key: it.key} }}
      )
    end
  end

  def toml_str(value)
    "\"#{value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
  end
end
