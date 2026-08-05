# frozen_string_literal: true

class Prog::Vm::Metal::MoveVm < Prog::Base
  subject_is :vm

  frame_reader :remote_storage_server_id

  def self.assemble(vm, vm_host, parent_id: nil)
    fail "Vm is not ready to move" unless vm.strand.label == "stopped_by_admin" && vm.prepare_to_move_set?
    fail "VmHost is not in the same location as the Vm" unless vm_host.location_id == vm.location_id
    fail "VmHost arch does not match Vm arch" unless vm_host.arch == vm.arch
    fail "Vm must have a single storage volume" unless vm.vm_storage_volumes.count == 1
    fail "VmHost does not accept slices and Vm is burstable" if vm.family == "burstable" && !vm_host.accepts_slices

    volume = vm.vm_storage_volumes.first
    fail "VmHost does not have sufficient space for the Vm" unless sufficient_space?(vm_host, vm, volume)

    DB.transaction do
      remote_storage_server = Prog::Storage::RemoteStorageServer::Nexus.assemble(volume.id).subject

      old_name = vm.name
      vm.update(name: "moving-with-#{remote_storage_server.ubid}")

      new_vm = Prog::Vm::Nexus.assemble(
        vm.public_key,
        vm.project_id,
        name: old_name,
        size: vm.display_size,
        unix_user: vm.unix_user,
        location_id: vm.location_id,
        boot_image: vm.boot_image,
        private_subnet_id: vm.user_nic.private_subnet_id,
        storage_volumes: [{encrypted: true, remote_storage_server_id: remote_storage_server.id}],
        enable_ip4: vm.ip4_enabled,
        arch: vm.arch,
        force_host_id: vm_host.id,
        remote_storage_server_id: remote_storage_server.id,
      ).subject
      if vm.sshable
        Sshable.create_with_id(new_vm, unix_user: vm.sshable.unix_user, host: "temp_#{vm.id}", raw_private_key_1: vm.sshable.raw_private_key_1)
      end

      Strand.create(
        parent_id:,
        prog: "Vm::Metal::MoveVm",
        label: "start",
        stack: [{"subject_id" => new_vm.id, "remote_storage_server_id" => remote_storage_server.id}],
      )
    end
  end

  def self.sufficient_space?(vm_host, vm, volume)
    cores_needed = [1, vm.vcpus * vm_host.total_cores / vm_host.total_cpus].max
    return false if vm_host.total_cores - vm_host.used_cores < cores_needed
    return false if vm_host.total_hugepages_1g - vm_host.used_hugepages_1g < vm.memory_gib

    vm_host.storage_devices.any? { it.available_storage_gib >= volume.size_gib }
  end

  label def start
    register_deadline("wait", 60 * 60)
    hop_wait
  end

  label def wait
    nap 30 unless vm.strand.label == "wait"
    nap 30 if vm.vm_storage_volumes.first.remote_storage_server_id
    hop_destroy
  end

  label def destroy
    RemoteStorageServer.incr_destroy(remote_storage_server_id)
    pop "vm moved"
  end
end
