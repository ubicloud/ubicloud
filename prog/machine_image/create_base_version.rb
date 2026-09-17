# frozen_string_literal: true

# Creates a new version of a base machine image from a base boot image in the
# download catalog (Prog::DownloadBootImage::BOOT_IMAGE_SHA256), verifies it by
# booting a throwaway VM from the freshly archived image and running a few
# commands, and only then promotes the version to be the machine image's latest.
#
# The machine image must already exist in the machine images service project;
# assemble fails otherwise.
class Prog::MachineImage::CreateBaseVersion < Prog::Base
  semaphore :destroy

  frame_reader :machine_image_id, :version, :url, :sha256sum
  frame_accessor :machine_image_version_id, :test_vm_id, :verify_failures

  MAX_VERIFY_FAILURES = 5

  def self.assemble(name:, version:, location_id:)
    fail MachineImageError, "no machine images service project configured" unless (image_project = Project[Config.machine_images_service_project_id])

    machine_image = MachineImage.first(project_id: image_project.id, location_id:, name:)
    fail MachineImageError, "machine image #{name.inspect} does not exist in the machine images service project" unless machine_image

    sha256sum = Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(name, machine_image.arch, version)
    fail MachineImageError, "unknown base boot image version #{name}-#{machine_image.arch}-#{version}" unless sha256sum

    fail MachineImageError, "no machine image store for #{machine_image.display_location}" unless machine_image.project.machine_image_store_for(location_id)

    url = Prog::DownloadBootImage.upstream_url(name, version, machine_image.arch)

    DB.transaction do
      machine_image.lock!
      fail MachineImageError, "version #{version} already exists for machine image #{name}" unless machine_image.versions_dataset.where(version:).empty?

      Strand.create(prog: "MachineImage::CreateBaseVersion", label: "create_version", stack: [{
        "machine_image_id" => machine_image.id,
        "version" => version,
        "url" => url,
        "sha256sum" => sha256sum,
      }])
    end
  end

  label def create_version
    self.machine_image_version_id = Prog::MachineImage::VersionMetalNexus.assemble_from_url(
      machine_image, version, url, sha256sum, store, set_as_latest: false,
    ).id
    hop_wait_version
  end

  label def wait_version
    case machine_image_version_metal.status
    when "ready"
      hop_create_test_vm
    when "failed"
      Clog.emit("Base machine image version archive failed", {base_machine_image_version_failure: {machine_image: machine_image.name, version:}})
      hop_failed
    else
      nap 15
    end
  end

  label def create_test_vm
    register_deadline("set_latest", 45 * 60)

    # The boot disk must be at least as large as the image's logical size.
    size_gib = [(machine_image_version.actual_size_mib / 1024.0).ceil, 10].max
    self.test_vm_id = Prog::Vm::Nexus.assemble_with_sshable(
      machine_image.project_id,
      sshable_unix_user: "ubi",
      location_id: machine_image.location_id,
      arch: machine_image.arch,
      storage_volumes: [{encrypted: true, size_gib:, machine_image_version_id:}],
      enable_ip4: true,
    ).id
    hop_wait_test_vm
  end

  label def wait_test_vm
    nap 10 unless test_vm.display_state == "running"
    hop_verify
  end

  label def verify
    nap 10 unless test_vm.sshable.available?

    begin
      # A reachable VM with a populated root filesystem proves the archived
      # image boots and is usable.
      test_vm.sshable.cmd("cat /etc/os-release")
      test_vm.sshable.cmd("sudo true")
    rescue Sshable::SshError => e
      self.verify_failures = (verify_failures || 0) + 1
      if verify_failures >= MAX_VERIFY_FAILURES
        Clog.emit("Base machine image version verification failed", {base_machine_image_version_failure: Util.exception_to_hash(e, into: {machine_image: machine_image.name, version:})})
        hop_failed
      end
      nap 10
    end

    hop_set_latest
  end

  label def set_latest
    DB.transaction do
      machine_image.lock!
      # Guard against the version having been destroyed while we were testing.
      machine_image.update(latest_version_id: machine_image_version_id) if machine_image_version_metal&.status == "ready"
    end
    test_vm.incr_destroy
    pop("msg" => "base machine image version created", "machine_image_version_id" => machine_image_version_id)
  end

  label def failed
    # Leave the version and test VM in place for inspection. Destroy the strand
    # to clean them up.
    nap 6 * 60 * 60
  end

  label def destroy
    test_vm&.incr_destroy
    MachineImageVersionMetal.where(id: machine_image_version_id).first&.incr_destroy
    pop "base machine image version creation destroyed"
  end

  def machine_image
    @machine_image ||= MachineImage[machine_image_id]
  end

  def machine_image_version
    @machine_image_version ||= MachineImageVersion[machine_image_version_id]
  end

  def machine_image_version_metal
    MachineImageVersionMetal[machine_image_version_id]
  end

  def store
    @store ||= machine_image.project.machine_image_store_for(machine_image.location_id)
  end

  def test_vm
    @test_vm ||= Vm[test_vm_id]
  end
end
