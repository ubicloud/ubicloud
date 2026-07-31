# frozen_string_literal: true

class Prog::Test::MoveVm < Prog::Test::Base
  frame_reader :vm_host_id
  frame_accessor :vm_id, :new_vm_id, :move_vm_strand_id, :markers

  MARKER_COUNT = 5

  def self.assemble(vm_host)
    project_id = Project.create(name: "move-vm-test").id
    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      project_id,
      sshable_unix_user: "ubi",
      size: "standard-2",
      location_id: vm_host.location_id,
      arch: vm_host.arch,
      enable_ip4: true,
    )

    Strand.create(
      prog: "Test::MoveVm",
      label: "wait_vm_running",
      stack: [{
        "vm_host_id" => vm_host.id,
        "vm_id" => vm_st.id,
        "markers" => [],
      }],
    )
  end

  label def wait_vm_running
    nap 10 unless vm.display_state == "running"
    hop_write_markers
  end

  label def write_markers
    sshable.cmd("sudo mkdir -p /opt/markers")
    MARKER_COUNT.times do |i|
      marker_file = "/opt/markers/marker-#{i}"
      sha256 = sshable.cmd("head -c 1M /dev/urandom | sudo tee :marker_file | sha256sum", marker_file:).split.first
      markers.append([marker_file, sha256])
    end
    strand.modified!(:stack)
    hop_prepare_to_move
  end

  label def prepare_to_move
    DB.transaction do
      vm.incr_prepare_to_move
      vm.incr_stop
    end
    hop_wait_stopped_by_admin
  end

  label def wait_stopped_by_admin
    nap 10 unless vm.strand.label == "stopped_by_admin"
    hop_move_vm
  end

  label def move_vm
    st = Prog::Vm::Metal::MoveVm.assemble(vm, vm_host)
    self.move_vm_strand_id = st.id
    self.new_vm_id = st.stack.first["subject_id"]
    hop_wait_move_vm
  end

  label def wait_move_vm
    nap 10 if Strand[move_vm_strand_id]
    hop_verify_new_vm
  end

  label def verify_new_vm
    markers.each do |marker_file, expected_sha256|
      actual_sha256 = new_sshable.cmd("sudo sha256sum :marker_file", marker_file:).split.first
      fail_test "Marker file #{marker_file} has unexpected sha256" unless actual_sha256 == expected_sha256
    end
    hop_destroy_vms
  end

  label def destroy_vms
    vm.incr_destroy
    new_vm.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 10 unless vm.nil? && new_vm.nil?
    pop "Test completed successfully"
  end

  label def failed
    nap 15
  end

  def vm_host
    @vm_host ||= VmHost[vm_host_id]
  end

  def vm
    @vm ||= Vm[vm_id]
  end

  def new_vm
    @new_vm ||= Vm[new_vm_id]
  end

  def sshable
    @sshable ||= vm.sshable
  end

  def new_sshable
    @new_sshable ||= new_vm.sshable
  end
end
