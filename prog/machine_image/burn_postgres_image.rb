# frozen_string_literal: true

require "aws-sdk-s3"
require "json"

class Prog::MachineImage::BurnPostgresImage < Prog::Base
  subject_is :machine_image_version_metal

  def self.assemble(machine_image, store, vm_host_id:, postgres_version:, version: nil, set_as_latest: true)
    version ||= Time.now.strftime("%Y%m%d.%H%M%S")
    store_prefix = "#{machine_image.project.ubid}/#{machine_image.ubid}/#{version}"

    DB.transaction do
      mi_version = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version: version
      )

      archive_kek = StorageKeyEncryptionKey.create_random(
        auth_data: "machine_image_version_#{machine_image.ubid}_#{version}"
      )

      mi_version_metal = MachineImageVersionMetal.create_with_id(
        mi_version,
        enabled: false,
        archive_kek_id: archive_kek.id,
        store_id: store.id,
        store_prefix: store_prefix
      )

      vm_host = VmHost[vm_host_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        machine_image.project_id,
        sshable_unix_user: "ubi",
        location_id: vm_host.location_id,
        name: "burn-pg#{postgres_version}-#{mi_version.ubid}",
        size: "standard-2",
        storage_volumes: [{encrypted: true, size_gib: 40}],
        boot_image: Config.default_boot_image_name,
        enable_ip4: true,
        force_host_id: vm_host_id
      )

      Strand.create_with_id(
        mi_version_metal,
        prog: "MachineImage::BurnPostgresImage",
        label: "wait_vm_running",
        stack: [{
          "subject_id" => mi_version_metal.id,
          "vm_id" => vm_st.subject.id,
          "vm_host_id" => vm_host_id,
          "postgres_version" => postgres_version,
          "set_as_latest" => set_as_latest
        }]
      )
    end
  end

  label def wait_vm_running
    register_deadline(nil, 60 * 60)

    if temp_vm.strand.label == "wait" && temp_vm_sshable?
      hop_install_postgres
    end

    nap 15
  end

  label def install_postgres
    pg_version = frame["postgres_version"]

    script_path = File.expand_path("../../rhizome/postgres/bin/build-postgres-image", __dir__)
    script_content = File.read(script_path)

    temp_vm.sshable.cmd("sudo bash -s -- :pg_version", pg_version:, stdin: script_content, timeout: 30 * 60)

    hop_stop_vm
  end

  label def stop_vm
    temp_vm.incr_stop
    hop_wait_vm_stopped
  end

  label def wait_vm_stopped
    if temp_vm.strand.label == "stopped"
      hop_archive
    end

    nap 10
  end

  label def archive
    sv = temp_vm.vm_storage_volumes.first
    unit_name = "archive_#{mi_version.ubid}"
    sshable = vm_host.sshable

    status = sshable.d_check(unit_name)
    case status
    when "Succeeded"
      sshable.d_clean(unit_name)
      hop_finish
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name,
        "sudo", "host/bin/archive-storage-volume",
        temp_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version,
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
    machine_image_version_metal.update(
      enabled: true,
      archive_size_mib: (archive_size_bytes / 1048576r).ceil
    )

    mi_version.update(actual_size_mib: temp_vm.storage_size_gib * 1024)

    if frame["set_as_latest"]
      mi_version.machine_image.update(latest_version_id: mi_version.id)
    end

    temp_vm.incr_destroy

    pop "postgres image burned and archived"
  end

  private

  def temp_vm
    @temp_vm ||= Vm[frame["vm_id"]]
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def mi_version
    @mi_version ||= machine_image_version_metal.machine_image_version
  end

  def temp_vm_sshable?
    temp_vm.sshable.cmd("true")
    true
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
    false
  end

  def archive_params_json
    sv = temp_vm.vm_storage_volumes.first
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
    s3.list_objects_v2(bucket: store.bucket, prefix: machine_image_version_metal.store_prefix).each_page do |page|
      total += page.contents.sum(&:size)
    end
    total
  end
end
