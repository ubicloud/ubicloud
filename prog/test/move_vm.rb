# frozen_string_literal: true

class Prog::Test::MoveVm < Prog::Test::Base
  frame_reader :vm_host_id
  frame_accessor :vm_id, :new_vm_id, :markers

  semaphore :destroy

  MARKER_COUNT = 5

  def self.assemble(vm_host, project_id: nil)
    DB.transaction do
      project_id ||= Project.create(name: "move-vm-test").id

      if vm_host.vhost_block_backends_dataset.where { version_code >= 500 }.empty?
        Prog::Storage::SetupVhostBlockBackend.assemble(VmHost.first.id, "v0.5.1", allocation_weight: 100)
      end

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        project_id,
        name: "test-vm-move",
        sshable_unix_user: "ubi",
        size: "standard-2",
        location_id: vm_host.location_id,
        arch: vm_host.arch,
        enable_ip4: true,
      )

      Strand.create(
        prog: "Test::MoveVm",
        label: "start",
        stack: [{
          "vm_host_id" => vm_host.id,
          "vm_id" => vm_st.id,
          "markers" => [],
        }],
      )
    end
  end

  label def start
    nap 10 unless vm.display_state == "running"
    sshable = vm.sshable
    sshable.cmd("sudo mkdir -p /opt/markers")
    MARKER_COUNT.times do |i|
      marker_file = "/opt/markers/marker-#{i}"
      sha256 = sshable.cmd("head -c 1M /dev/urandom | sudo tee :marker_file | sha256sum", marker_file:).split.first
      markers.append([marker_file, sha256])
    end
    strand.modified!(:stack)
    vm.incr_prepare_to_move
    vm.incr_stop
    hop_move_vm
  end

  label def move_vm
    nap 10 unless vm.strand.label == "stopped_by_admin"
    self.new_vm_id = Prog::Vm::Metal::MoveVm.assemble(vm, VmHost[vm_host_id], parent_id: strand.id).stack.first["subject_id"]
    hop_wait_vm_moved
  end

  label def wait_vm_moved
    reap(:verify_new_vm)
  end

  label def verify_new_vm
    sshable = new_vm_sshable
    markers.each do |marker_file, expected_sha256|
      actual_sha256 = sshable.cmd("sudo sha256sum :marker_file", marker_file:).split.first
      fail_test "Marker file #{marker_file} has unexpected sha256" unless actual_sha256 == expected_sha256
    end
    hop_destroy
  end

  label def destroy
    Vm.incr_destroy(vm_ids)
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 10 unless Vm.where(id: vm_ids).empty?
    pop "Test completed successfully"
  end

  label def failed
    nap 15
  end

  def vm
    @vm ||= Vm[vm_id]
  end

  def vm_ids
    [vm_id, new_vm_id].compact
  end

  def vm_sshable
    @vm_sshable ||= vm.sshable
  end

  def new_vm_sshable
    @new_vm_sshable ||= Vm[new_vm_id].sshable
  end
end
