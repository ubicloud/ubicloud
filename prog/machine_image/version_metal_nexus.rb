# frozen_string_literal: true

require "aws-sdk-s3"
require "json"

class Prog::MachineImage::VersionMetalNexus < Prog::Base
  subject_is :machine_image_version_metal

  frame_reader :source_vm_id, :destroy_source_after,
    :url, :sha256sum, :vm_host_id, :vhost_block_backend_version,
    :set_as_latest
  frame_accessor :physical_size_bytes, :logical_size_bytes, :archive_failures

  MAX_ARCHIVE_FAILURES = 3

  def self.assemble_from_vm(machine_image, version, source_vm, store,
    destroy_source_after: false, set_as_latest: true)
    fail MachineImageError, "Source VM arch (#{source_vm.arch}) does not match machine image arch (#{machine_image.arch})" unless source_vm.arch == machine_image.arch
    fail MachineImageError, "Source VM must be a metal VM" unless source_vm.vm_host
    fail MachineImageError, "Source VM must have only one storage volume" unless source_vm.vm_storage_volumes.length == 1
    fail MachineImageError, "Source VM must be stopped" unless source_vm.display_state == "stopped"

    sv = source_vm.vm_storage_volumes.first
    fail MachineImageError, "Source VM's storage volume doesn't support machine images" unless sv.track_written
    fail MachineImageError, "Source VM's storage volume must be encrypted" unless sv.key_encryption_key_1
    fail MachineImageError, "Source VM's storage volume is larger than #{Config.machine_image_max_size_gib} GiB" if sv.size_gib > Config.machine_image_max_size_gib

    create_strand(machine_image, version, store,
      "source_vm_id" => source_vm.id,
      "vm_host_id" => source_vm.vm_host_id,
      "destroy_source_after" => destroy_source_after,
      "set_as_latest" => set_as_latest)
  end

  def self.assemble_from_url(machine_image, version, url, sha256sum, store, set_as_latest: true)
    vbb = VhostBlockBackend
      .where(vm_host_id: VmHost.where(location_id: machine_image.location_id).select(:id))
      .where { version_code >= VhostBlockBackend::MIN_ARCHIVE_SUPPORT_VERSION }
      .order { random.function }
      .first
    fail "no vm host with archive support found in location" unless vbb

    create_strand(machine_image, version, store,
      "url" => url,
      "sha256sum" => sha256sum,
      "vm_host_id" => vbb.vm_host_id,
      "vhost_block_backend_version" => vbb.version,
      "set_as_latest" => set_as_latest)
  end

  def self.create_strand(machine_image, version, store, frame)
    DB.transaction do
      miv = MachineImageVersion.create(machine_image_id: machine_image.id, version:, actual_size_mib: nil)
      archive_kek = StorageKeyEncryptionKey.create_random(auth_data: "machine_image_version_#{miv.ubid}_#{miv.version}")
      MachineImageVersionMetal.create_with_id(miv,
        status: "creating",
        pinned_source_vm_id: frame["source_vm_id"],
        archive_kek_id: archive_kek.id,
        store_id: store.id,
        store_prefix: "#{machine_image.project.ubid}/#{machine_image.ubid}/#{miv.version}")

      Strand.create_with_id(miv,
        prog: "MachineImage::VersionMetalNexus",
        label: "archive",
        stack: [frame])
    end
  end

  label def archive
    # 4 minutes per 10 GiB for VM sources, fixed 1 hour for URL sources.
    register_deadline("wait", source_vm_id ? Vm[source_vm_id].storage_size_gib * 24 : 3600)

    state = sshable.d_check(archive_unit)
    case state
    when "Succeeded"
      capture_stats
      sshable.d_clean(archive_unit)
      hop_finish_archive
    when "Failed"
      self.archive_failures = (archive_failures || 0) + 1
      if archive_failures >= MAX_ARCHIVE_FAILURES
        machine_image_version_metal.update(status: "failed", pinned_source_vm_id: nil)
        hop_destroy_objects
      else
        # retry in 60 seconds
        sshable.d_clean(archive_unit)
        nap 60
      end
    when "NotStarted"
      sshable.d_run(archive_unit, *archive_command, stdin: archive_params, log: false)
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit("Unexpected daemonizer2 status: #{state}")
      nap 60
    end
  end

  label def finish_archive
    sshable.cmd("sudo rm -f :stats_path", stats_path: stats_file)

    machine_image_version_metal.update(
      status: "ready",
      archive_size_mib: (physical_size_bytes/1048576r).ceil,
      pinned_source_vm_id: nil,
    )
    machine_image_version_metal.create_billing_record

    miv = machine_image_version_metal.machine_image_version
    miv.update(actual_size_mib: (logical_size_bytes/1048576r).ceil)

    if destroy_source_after
      Vm[source_vm_id].incr_destroy
    end

    if set_as_latest
      miv.machine_image.update(latest_version_id: miv.id)
    end

    hop_wait
  end

  label def wait
    nap 365 * 24 * 60 * 60
  end

  label def destroy
    register_deadline(nil, 600)
    decr_destroy

    if machine_image_version_metal.status == "creating"
      sshable.d_stop(archive_unit) if sshable.d_check(archive_unit) == "InProgress"
      sshable.d_clean(archive_unit)
      machine_image_version_metal.update(pinned_source_vm_id: nil)
    end

    miv = machine_image_version_metal.machine_image_version
    # Serialize with other `VersionMetalNexus#destroy` labels of the same
    # machine image. This is to prevent latest_version_id from being updated
    # to a concurrently destroyed version when auto-reassigning it.
    mi = miv.machine_image(&:for_update)

    # Serialize with other transactions that check or update `status`.
    machine_image_version_metal.lock!

    machine_image_version_metal.update(status: "destroying")
    machine_image_version_metal.active_billing_records.each(&:finalize)

    if mi.latest_version_id == miv.id
      new_latest = mi.versions_dataset
        .association_join(:metal)
        .where(Sequel[:metal][:status] => "ready")
        .reverse(:created_at)
        .get(Sequel[:machine_image_version][:id])
      mi.update(latest_version_id: new_latest)
    end

    hop_wait_vms
  end

  label def wait_vms
    nap 30 unless machine_image_version_metal.vm_storage_volumes_dataset.empty?
    hop_destroy_objects
  end

  label def destroy_objects
    store = machine_image_version_metal.store
    s3_client = Aws::S3::Client.new(
      access_key_id: store.access_key,
      secret_access_key: store.secret_key,
      endpoint: store.endpoint,
      region: store.region,
      force_path_style: true,
      http_open_timeout: 5,
      http_read_timeout: 20,
      retry_limit: 0,
    )

    # delete one page of objects at a time to avoid a long running label
    page = s3_client.list_objects_v2(
      bucket: store.bucket,
      prefix: machine_image_version_metal.store_prefix,
      max_keys: 1000,
    )

    if page.contents.empty?
      if machine_image_version_metal.status == "failed"
        hop_failed
      else
        hop_finish_destroy
      end
    end

    response = s3_client.delete_objects(
      bucket: store.bucket,
      delete: {
        objects: page.contents.map { |obj| {key: obj.key} },
      },
    )

    unless response.errors.empty?
      miv = machine_image_version_metal.machine_image_version
      Clog.emit("Failed to delete some machine image archive objects", {
        machine_image: miv.machine_image.ubid,
        version: miv.version,
        count: response.errors.size,
        first_error: response.errors.first.to_h,
      })

      # nap longer to space out retries
      nap 30
    end

    nap 0
  end

  label def finish_destroy
    miv = machine_image_version_metal.machine_image_version
    archive_kek = machine_image_version_metal.archive_kek
    machine_image_version_metal.destroy
    archive_kek.destroy
    miv.destroy
    pop "Metal machine image version is destroyed"
  end

  label def failed
    # Nothing else to do. Don't exit the strand in case user wants to issue a
    # destroy command after a failure to clean up the db records.
    #
    # YYY: A likely failure reason here is transient object store put errors.
    # After adding (a) healthcheck for machine image stores, and (b) a way to
    # verify that the cause was object store put outage, we can also unregister
    # the "wait" deadline here to avoid redundant pages. For now, we'll just get
    # a deadline page unless the user destroys the failed version.
    nap 365 * 24 * 60 * 60
  end

  def vm_host
    @vm_host ||= VmHost[vm_host_id]
  end

  def sshable
    vm_host.sshable
  end

  def archive_unit
    "archive_#{machine_image_version_metal.machine_image_version.ubid}"
  end

  def stats_file
    "/tmp/archive_stats_#{machine_image_version_metal.machine_image_version.ubid}.json"
  end

  private

  def capture_stats
    stats = JSON.parse(sshable.cmd("cat :stats_path", stats_path: stats_file))
    self.physical_size_bytes = stats["physical_size_bytes"]
    self.logical_size_bytes = stats["logical_size_bytes"]
  end

  def archive_command
    if source_vm_id
      source_vm = Vm[source_vm_id]
      sv = source_vm.vm_storage_volumes.first
      ["sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version, stats_file]
    else
      ["sudo", "host/bin/archive-url", url, sha256sum, vhost_block_backend_version, stats_file]
    end
  end

  def archive_params
    store = machine_image_version_metal.store
    target_conf = {
      endpoint: store.endpoint,
      region: store.region,
      bucket: store.bucket,
      prefix: machine_image_version_metal.store_prefix,
      access_key_id: store.access_key,
      secret_access_key: store.secret_key,
      archive_kek: machine_image_version_metal.archive_kek.secret_key_material_hash,
    }
    payload = {target_conf:}
    if source_vm_id
      payload[:kek] = Vm[source_vm_id].vm_storage_volumes.first.key_encryption_key_1.secret_key_material_hash
    end
    payload.to_json
  end
end
