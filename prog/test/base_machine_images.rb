# frozen_string_literal: true

require "json"

class Prog::Test::BaseMachineImages < Prog::Test::Base
  semaphore :destroy_base_machine_images
  frame_accessor :base_machine_image_version_ids
  frame_reader :location_id, :base_image_names, :arch

  def self.assemble(location_id:, arch:, base_image_names:)
    Strand.create(
      prog: "Test::BaseMachineImages",
      label: "setup_base_machine_images",
      stack: [{
        "location_id" => location_id,
        "base_image_names" => base_image_names,
        "arch" => arch,
      }],
    )
  end

  label def setup_base_machine_images
    p = Project.create_with_id(
      Config.machine_images_service_project_id,
      name: "machine-images-resources",
    )
    store = MachineImageStore.create(
      project_id: p.id,
      location_id:,
      provider: "r2",
      region: "auto",
      endpoint: Config.e2e_machine_images_endpoint,
      bucket: Config.e2e_machine_images_bucket,
      access_key: Config.e2e_machine_images_access_key,
      secret_key: Config.e2e_machine_images_secret_key,
    )
    self.base_machine_image_version_ids = base_image_names.map { |base_image_name|
      mi = MachineImage.create(
        project_id: p.id,
        name: base_image_name,
        location_id:,
        arch:,
      )
      version, sha256sum = Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(base_image_name, arch).max
      url = Prog::DownloadBootImage.upstream_url(base_image_name, version, arch)
      Prog::MachineImage::VersionMetalNexus.assemble_from_url(mi, version, url, sha256sum, store).id
    }

    hop_wait_setup_base_machine_images
  end

  label def wait_setup_base_machine_images
    base_machine_image_version_ids.each do |miv_id|
      metal = MachineImageVersionMetal[miv_id]
      case metal.status
      when "failed"
        fail_test "Machine image version #{metal.machine_image_version.machine_image.name} failed"
      when "ready"
        next
      else
        nap 15
      end
    end
    hop_wait
  end

  label def wait
    when_destroy_base_machine_images_set? do
      base_machine_image_version_ids.each do |miv_id|
        MachineImageVersionMetal[miv_id].incr_destroy
      end
      hop_wait_destroy
    end

    nap 60 * 60
  end

  label def wait_destroy
    nap 15 unless MachineImageVersionMetal.where(id: base_machine_image_version_ids).empty?
    pop "Base machine images destroyed!"
  end

  label def failed
    nap 15
  end
end
