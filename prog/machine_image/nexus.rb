# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::MachineImage::Nexus < Prog::Base
  subject_is :machine_image

  def vm
    @vm ||= machine_image.vm
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

  label def start
    register_deadline(nil, 24 * 60 * 60)

    fail "VM must be stopped to create a machine image" unless vm.display_state == "stopped"
    fail "VM has no boot volume" unless boot_volume
    fail "VM lacks write tracking — cannot create a reliable archive" unless boot_volume.vhost_block_backend_id

    hop_clean_cloud_init
  end

  label def clean_cloud_init
    # Skip for encrypted boot volumes — ubiblk XTS encryption makes the raw
    # disk unmountable without ubiblk itself.  Cloud-init will still re-init
    # because the new VM gets a fresh nocloud disk with a different instance-id.
    if boot_volume.key_encryption_key_1
      Clog.emit("Skipping cloud-init cleanup for encrypted boot volume")
      hop_create_kek_or_archive
    end

    daemon_name = "cloudinit_clean_#{machine_image.ubid}"
    case host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_create_kek_or_archive
    when "NotStarted"
      params = {"disk_file" => disk_file_path}
      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/clean-cloud-init' :daemon_name", daemon_name:, stdin: params.to_json)
    when "Failed"
      # Cloud-init cleanup is best-effort — log warning and continue with archiving
      stderr = begin
        host.sshable.cmd("cat var/log/:daemon_name.stderr", daemon_name:).strip
      rescue
        nil
      end
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      Clog.emit("Cloud-init cleanup failed (continuing with archive)", {cloud_init_cleanup_failed: {ubid: machine_image.ubid, stderr:}})
      hop_create_kek_or_archive
    end

    nap 5
  end

  label def create_kek_or_archive
    if machine_image.encrypted
      hop_create_kek
    else
      hop_archive
    end
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
      auth_data: machine_image.ubid
    )
    machine_image.update(key_encryption_key_1_id: kek.id)

    hop_archive
  end

  label def archive
    daemon_name = "archive_#{machine_image.ubid}"
    case host.sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_verify_boot
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
      machine_image.update(state: "failed")
      Clog.emit("Failed to create machine image archive", {machine_image_archive_failed: {ubid: machine_image.ubid, stderr:}})
      hop_wait
    end

    nap 15
  end

  VERIFY_BOOT_TIMEOUT = 5 * 60 # 5 minutes

  label def verify_boot
    machine_image.update(state: "verifying")

    st = Prog::Vm::Nexus.assemble(
      vm.public_key,
      machine_image.project_id,
      name: "mi-verify-#{machine_image.ubid}",
      size: "standard-2",
      location_id: machine_image.location_id,
      boot_image: nil,
      machine_image_id: machine_image.id,
      enable_ip4: false,
      arch: vm.arch,
      force_host_id: vm.vm_host_id
    )
    update_stack({"verify_vm_id" => st.subject.id, "verify_deadline" => Time.now + VERIFY_BOOT_TIMEOUT})

    hop_wait_verify_boot
  end

  label def wait_verify_boot
    verify_vm = Vm[frame["verify_vm_id"]]

    if verify_vm.nil? || verify_vm.display_state == "failed"
      hop_fail_verify_boot
    elsif verify_vm.display_state == "running"
      verify_vm.incr_destroy
      hop_finish
    elsif Time.now > Time.parse(frame["verify_deadline"].to_s)
      hop_fail_verify_boot
    end

    nap 15
  end

  label def fail_verify_boot
    verify_vm = Vm[frame["verify_vm_id"]]
    verify_vm&.incr_destroy

    machine_image.update(state: "failed")
    Clog.emit("Machine image failed boot verification", {machine_image_verify_failed: {ubid: machine_image.ubid}})
    hop_wait
  end

  label def finish
    machine_image.update(state: "available", size_gib: boot_volume.size_gib)

    if machine_image.project.billable && machine_image.active_billing_records.empty?
      billing_rate = BillingRate.from_resource_properties("MachineImageStorage", "standard", machine_image.location.name)
      if billing_rate
        BillingRecord.create(
          project_id: machine_image.project_id,
          resource_id: machine_image.id,
          resource_name: machine_image.name,
          billing_rate_id: billing_rate["id"],
          amount: machine_image.size_gib
        )
      else
        Clog.emit("No billing rate found for machine image", {machine_image_billing_rate_missing: {ubid: machine_image.ubid, location: machine_image.location.name}})
      end
    end

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end
    if machine_image.state == "failed" && machine_image.created_at < Time.now - 3600
      hop_destroy
    end
    nap 30
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    # Block deletion if any VMs still have an active (non-fully-synced) dependency
    active_deps = VmStorageVolume.where(machine_image_id: machine_image.id)
      .exclude { source_fetch_fetched >= source_fetch_total }
      .count

    if active_deps > 0
      Clog.emit("Cannot destroy machine image: VMs still actively fetching",
        {machine_image: machine_image.ubid, active_dependencies: active_deps})
      nap 60
    end

    machine_image.active_billing_records.each(&:finalize)
    machine_image.update(state: "destroying")

    hop_destroy_record
  end

  label def destroy_record
    delete_s3_objects

    if machine_image.encrypted
      kek = machine_image.key_encryption_key_1
      machine_image.update(key_encryption_key_1_id: nil)
      kek&.destroy
    end

    machine_image.destroy

    pop "machine image destroyed"
  end

  private

  def archive_bin
    vbb_version = boot_volume.vhost_block_backend_version || "v0.4.0"
    "/opt/vhost-block-backend/#{vbb_version}/archive"
  end

  def disk_file_path
    File.join(File.dirname(device_config_path), "disk.raw")
  end

  def device_config_path
    storage_device_name = boot_volume.storage_device&.name || "DEFAULT"
    device_dir = (storage_device_name == "DEFAULT") ? "/var/storage" : "/var/storage/devices/#{storage_device_name}"
    "#{device_dir}/#{vm_name}/#{boot_volume.disk_index}/vhost-backend.conf"
  end

  def target_config_path
    "/tmp/archive-target-#{machine_image.ubid}.toml"
  end

  def target_config_toml
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
    lines << "session_token.ref = \"s3-session-token\""

    if machine_image.encrypted
      lines << "archive_kek.ref = \"archive-kek\""
    end

    lines << ""
    lines << "[secrets.s3-key-id]"
    lines << "source.file = \"/run/secrets/#{vm_name}/s3-key-id.pipe\""
    lines << ""
    lines << "[secrets.s3-secret-key]"
    lines << "source.file = \"/run/secrets/#{vm_name}/s3-secret-key.pipe\""
    lines << ""
    lines << "[secrets.s3-session-token]"
    lines << "source.file = \"/run/secrets/#{vm_name}/s3-session-token.pipe\""

    if machine_image.encrypted
      lines << ""
      lines << "[secrets.archive-kek]"
      lines << "source.file = \"/run/secrets/#{vm_name}/archive-kek.pipe\""
    end

    lines.join("\n") + "\n"
  end

  def archive_params
    creds = CloudflareR2.create_temporary_credentials(
      bucket: machine_image.s3_bucket,
      prefix: machine_image.s3_prefix,
      permission: "object-read-write"
    )

    params = {
      "archive_bin" => archive_bin,
      "device_config" => device_config_path,
      "target_config_path" => target_config_path,
      "target_config_content" => target_config_toml,
      "encrypt" => machine_image.encrypted,
      "s3_key_id" => creds[:access_key_id],
      "s3_secret_key" => creds[:secret_access_key],
      "s3_session_token" => creds[:session_token],
      "vm_name" => vm_name
    }

    if machine_image.encrypted
      kek = machine_image.key_encryption_key_1
      params["archive_kek"] = kek.key
    end

    # Pass the disk KEK so the archive script can decrypt the source disk
    if boot_volume.key_encryption_key_1
      params["disk_kek"] = boot_volume.key_encryption_key_1.key
    end

    params
  end

  def delete_s3_objects
    creds = CloudflareR2.create_temporary_credentials(
      bucket: machine_image.s3_bucket,
      prefix: machine_image.s3_prefix,
      permission: "object-read-write"
    )

    client = Aws::S3::Client.new(
      endpoint: machine_image.s3_endpoint,
      access_key_id: creds[:access_key_id],
      secret_access_key: creds[:secret_access_key],
      session_token: creds[:session_token],
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
