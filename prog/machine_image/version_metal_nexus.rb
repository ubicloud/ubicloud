# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::MachineImage::VersionMetalNexus < Prog::Base
  subject_is :machine_image_version_metal

  def self.assemble_from_vm(machine_image, version, source_vm, store, destroy_source_after: false, set_as_latest: true)
    fail "source vm must be a metal vm" unless source_vm.vm_host
    fail "source vm must have only one storage volume" unless source_vm.vm_storage_volumes.count == 1
    fail "source vm must be stopped" unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail "source vm's vhost block backend must support archive" unless sv.vhost_block_backend&.supports_archive?
    fail "source vm's storage volume must be encrypted" unless sv.key_encryption_key_1

    DB.transaction do
      metal = create_rows(machine_image, version, store)
      Strand.create_with_id(metal,
        prog: "MachineImage::VersionMetalNexus",
        label: "start",
        stack: [{
          "source" => "vm",
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
      metal = create_rows(machine_image, version, store)
      Strand.create_with_id(metal,
        prog: "MachineImage::VersionMetalNexus",
        label: "start",
        stack: [{
          "source" => "url",
          "url" => url,
          "sha256sum" => sha256sum,
          "vm_host_id" => vbb.vm_host_id,
          "vhost_block_backend_version" => vbb.version,
          "set_as_latest" => set_as_latest,
        }])
    end
  end

  def self.create_rows(machine_image, version, store)
    miv = MachineImageVersion.create(machine_image_id: machine_image.id, version:)
    archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{miv.ubid}_#{version}")
    MachineImageVersionMetal.create_with_id(miv,
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix: "#{machine_image.project.ubid}/#{machine_image.ubid}/#{version}")
  end

  # Archive creation is not safely interruptible, so we skip the default
  # before_run hop-to-destroy. The wait label checks for destroy explicitly
  # once creation has succeeded.
  def before_run
  end

  label def start
    hop_archive
  end

  label def archive
    register_deadline(nil, archive_deadline)

    status = sshable.d_check(unit_name)
    case status
    when "Succeeded"
      stats = JSON.parse(sshable.cmd("cat :stats_path", stats_path: stats_file_path))
      update_stack(stats.slice("physical_size_bytes", "logical_size_bytes"))
      sshable.d_clean(unit_name)
      hop_finish_create
    when "Failed"
      sshable.d_restart(unit_name)
      nap 60
    when "NotStarted"
      sshable.d_run(unit_name, *archive_command, stdin: archive_params_json, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit("Unexpected daemonizer2 status: #{status}")
      nap 60
    end
  end

  label def finish_create
    sshable.cmd("sudo rm -f :stats_path", stats_path: stats_file_path)

    DB.transaction do
      # Explicit lock to serialize with request_destroy / destroy_version's
      # FOR UPDATE; see below for how destroy is detected. If one is queued,
      # skip finalization and let wait -> destroy run.
      machine_image_version_metal.this.for_share.first
      # Live query rather than destroy_set?: the prog's SemSnap is populated
      # at strand tick start, before we take FOR SHARE, so it can miss a
      # destroy semaphore committed in the gap. A fresh SELECT inside the
      # lock sees any committed semaphore up to the point we hold it.
      unless Semaphore.where(strand_id: strand.id, name: "destroy").any?
        machine_image_version_metal.update(
          enabled: true,
          archive_size_mib: (frame["physical_size_bytes"]/1048576r).ceil,
        )
        miv.update(actual_size_mib: (frame["logical_size_bytes"]/1048576r).ceil)
        source_vm.incr_destroy if vm_source? && frame["destroy_source_after"]
        if frame["set_as_latest"]
          miv.machine_image.update(latest_version_id: miv.id)
        end
      end
    end

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end
    nap 6 * 60 * 60
  end

  label def destroy
    register_deadline(nil, 600)
    machine_image_version_metal.update(enabled: false)
    hop_destroy_objects
  end

  label def destroy_objects
    page = s3_client.list_objects_v2(
      bucket: machine_image_version_metal.store.bucket,
      prefix: machine_image_version_metal.store_prefix,
      max_keys: 1000,
    )

    hop_finish_destroy if page.contents.empty?

    response = s3_client.delete_objects(
      bucket: machine_image_version_metal.store.bucket,
      delete: {
        objects: page.contents.map { |obj| {key: obj.key} },
      },
    )

    unless response.errors.empty?
      Clog.emit("Failed to delete some machine image archive objects", {
        machine_image: miv.machine_image.ubid,
        version: miv.version,
        count: response.errors.size,
        first_error: response.errors.first.to_h,
      })
      nap 30
    end

    nap 0
  end

  label def finish_destroy
    archive_kek = machine_image_version_metal.archive_kek
    machine_image_version_metal.destroy
    archive_kek.destroy
    miv.destroy
    pop "Metal machine image version is destroyed"
  end

  def miv
    @miv ||= machine_image_version_metal.machine_image_version
  end

  def sshable
    vm_source? ? source_vm.vm_host.sshable : vm_host.sshable
  end

  def source_vm
    @source_vm ||= Vm[frame["source_vm_id"]]
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def unit_name
    "archive_#{miv.ubid}"
  end

  def vm_source?
    frame["source"] == "vm"
  end

  def archive_deadline
    vm_source? ? source_vm.storage_size_gib * 24 : 3600
  end

  def archive_command
    if vm_source?
      sv = source_vm.vm_storage_volumes.first
      ["sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version, stats_file_path]
    else
      ["sudo", "host/bin/archive-url", frame["url"], frame["sha256sum"], frame["vhost_block_backend_version"], stats_file_path]
    end
  end

  def stats_file_path
    "/tmp/archive_stats_#{miv.ubid}.json"
  end

  def archive_params_json
    payload = {target_conf: store_target_conf}
    if vm_source?
      sv = source_vm.vm_storage_volumes.first
      payload[:kek] = sv.key_encryption_key_1.secret_key_material_hash
    end
    payload.to_json
  end

  def store_target_conf
    store = machine_image_version_metal.store
    {
      endpoint: store.endpoint,
      region: store.region,
      bucket: store.bucket,
      prefix: machine_image_version_metal.store_prefix,
      access_key_id: store.access_key,
      secret_access_key: store.secret_key,
      archive_kek: machine_image_version_metal.archive_kek.secret_key_material_hash,
    }
  end

  def s3_client
    @s3_client ||= begin
      store = machine_image_version_metal.store
      Aws::S3::Client.new(
        access_key_id: store.access_key,
        secret_access_key: store.secret_key,
        endpoint: store.endpoint,
        region: store.region,
        force_path_style: true,
        http_open_timeout: 5,
        http_read_timeout: 20,
        retry_limit: 0,
      )
    end
  end
end
