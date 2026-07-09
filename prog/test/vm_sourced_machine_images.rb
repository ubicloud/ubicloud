# frozen_string_literal: true

class Prog::Test::VmSourcedMachineImages < Prog::Test::Base
  frame_reader :location_id, :arch, :project_id, :machine_image_id
  frame_accessor :vm_id, :round, :machine_image_version_ids, :markers

  MARKERS_PER_ROUND = 5
  NUM_ROUNDS = 2

  def self.assemble(location_id:, arch:)
    DB.transaction do
      project_id = Project.create(name: "vm-sourced-machine-images").id
      machine_image_id = MachineImage.create(
        project_id:,
        name: "vm-sourced-machine-image",
        location_id:,
        arch:,
      ).id
      vm_id = Prog::Vm::Nexus.assemble_with_sshable(
        project_id,
        sshable_unix_user: "ubi",
        size: "burstable-1",
        location_id:,
        arch:,
        enable_ip4: true,
      ).id

      Strand.create(
        prog: "Test::VmSourcedMachineImages",
        label: "wait_initial_vm_running",
        stack: [{
          "location_id" => location_id,
          "arch" => arch,
          "project_id" => project_id,
          "machine_image_id" => machine_image_id,
          "round" => 1,
          "markers" => [],
          "machine_image_version_ids" => [],
          "vm_id" => vm_id,
        }],
      )
    end
  end

  label def wait_initial_vm_running
    nap 10 unless vm.display_state == "running"
    hop_write_markers_and_stop
  end

  label def write_markers_and_stop
    sshable.cmd("sudo mkdir -p /opt/markers")
    MARKERS_PER_ROUND.times do |i|
      marker_file = "/opt/markers/round-#{round}-marker-#{i}"
      sha256 = sshable.cmd("head -c 1M /dev/urandom | sudo tee :marker_file | sha256sum", marker_file:).split.first
      markers.append([marker_file, sha256])
    end
    strand.modified!(:stack)
    vm.incr_stop
    hop_wait_source_vm_stopped
  end

  label def wait_source_vm_stopped
    nap 10 unless vm.display_state == "stopped"
    hop_capture_machine_image
  end

  label def capture_machine_image
    st = Prog::MachineImage::VersionMetalNexus.assemble_from_vm(
      machine_image,
      "v#{round}",
      vm,
      machine_image_store,
      destroy_source_after: true,
    )
    machine_image_version_ids.append(st.id)
    hop_wait_machine_image_captured
  end

  label def wait_machine_image_captured
    metal = MachineImageVersionMetal[machine_image_version_ids.last]
    case metal.status
    when "failed"
      fail_test "Machine image version #{round} failed"
    when "ready"
      nil
    else
      nap 15
    end
    hop_wait_source_vm_destroyed
  end

  label def wait_source_vm_destroyed
    nap 10 unless vm.nil?
    hop_create_vm_from_machine_image
  end

  label def create_vm_from_machine_image
    self.vm_id = Prog::Vm::Nexus.assemble_with_sshable(
      project_id,
      sshable_unix_user: "ubi",
      size: "burstable-1",
      location_id:,
      arch:,
      boot_image: "#{machine_image.name}@latest",
      enable_ip4: true,
    ).id
    hop_wait_vm_from_machine_image_running
  end

  label def wait_vm_from_machine_image_running
    nap 10 unless vm.display_state == "running"
    hop_verify_markers
  end

  label def verify_markers
    markers.each do |marker_file, expected_sha256|
      actual_sha256 = sshable.cmd("sudo sha256sum :marker_file", marker_file:).split.first
      fail_test "Marker file #{marker_file} has unexpected sha256" unless actual_sha256 == expected_sha256
    end

    self.round += 1
    if round <= NUM_ROUNDS
      hop_write_markers_and_stop
    else
      MachineImageVersionMetal.incr_destroy(machine_image_version_ids)
      vm.incr_destroy
      hop_wait_resources_destroyed
    end
  end

  label def wait_resources_destroyed
    nap 10 unless vm.nil? && MachineImageVersionMetal.where(id: machine_image_version_ids).empty?
    pop "Test completed successfully"
  end

  label def failed
    nap 15
  end

  def machine_image_store
    @machine_image_store ||= MachineImageStore.first(
      project_id: Config.machine_images_service_project_id,
      location_id:,
    )
  end

  def machine_image
    @machine_image ||= MachineImage[machine_image_id]
  end

  def vm
    @vm ||= Vm[vm_id]
  end

  def sshable
    @sshable ||= vm.sshable
  end
end
