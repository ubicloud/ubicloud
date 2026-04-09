# frozen_string_literal: true

require "aws-sdk-s3"

class Prog::MachineImage::DestroyVersionMetal < Prog::Base
  subject_is :machine_image_version_metal

  def self.assemble(machine_image_version_metal)
    DB.transaction do
      # Mark the version as disabled first to acquire a row lock and prevent
      # concurrent creation of storage volumes based on this version.
      machine_image_version_metal.update(enabled: false)

      miv = machine_image_version_metal.machine_image_version
      if miv.machine_image.latest_version_id == miv.id
        fail "Cannot destroy the latest version of a machine image"
      end

      unless machine_image_version_metal.vm_storage_volumes_dataset.empty?
        fail "VMs are still using this machine image version"
      end

      Strand.create_with_id(machine_image_version_metal,
        prog: "MachineImage::DestroyVersionMetal",
        label: "destroy_objects")
    end
  end

  label def destroy_objects
    register_deadline(nil, 600)

    mi_version = machine_image_version_metal.machine_image_version
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

    hop_update_database if page.contents.empty?

    response = s3_client.delete_objects(
      bucket: store.bucket,
      delete: {
        objects: page.contents.map { |obj| {key: obj.key} },
      },
    )

    unless response.errors.empty?
      Clog.emit("Failed to delete some machine image archive objects", {
        machine_image: mi_version.machine_image.ubid,
        version: mi_version.version,
        count: response.errors.size,
        first_error: response.errors.first.to_h,
      })

      # nap longer to space out retries
      nap 30
    end

    nap 0
  end

  label def update_database
    version = machine_image_version_metal.machine_image_version
    archive_kek = machine_image_version_metal.archive_kek
    machine_image_version_metal.destroy
    archive_kek.destroy
    version.destroy

    pop "Metal machine image version is destroyed"
  end
end
