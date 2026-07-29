# frozen_string_literal: true

# Moves a Vm that has been prepared to move (see the "prepare_to_move" admin
# action) to a new VmHost. The old Vm's boot volume is served to the new host
# over the network by a Prog::Storage::RemoteStorageServer::Nexus, and the new
# Vm streams its storage from there until it catches up, at which point the
# remote storage server is torn down.
class Prog::Vm::Metal::MoveVm < Prog::Base
  subject_is :vm

  frame_reader :remote_storage_server_id

  # The new Vm, created by this method, is the subject of this prog. The
  # original Vm is left running under a temporary name, still fully
  # provisioned, until it is cleaned up separately.
  def self.assemble(vm, vm_host)
    # A Vm prepared to move has its "prepare_to_move" semaphore set, and its
    # strand hops to "stopped_by_admin" once actually stopped (see
    # Prog::Vm::Metal::Nexus#stopped). The semaphore itself is left set as
    # the durable marker that a move is pending.
    fail "Vm is not ready to move" unless vm.strand.label == "stopped_by_admin" && vm.prepare_to_move_set?
    fail "VmHost is not in the same location as the Vm" unless vm_host.location_id == vm.location_id
    fail "Vm must have a single storage volume to move" unless vm.vm_storage_volumes.count == 1

    volume = vm.vm_storage_volumes.first
    fail "VmHost does not have sufficient space for the Vm" unless sufficient_space?(vm_host, vm, volume)

    DB.transaction do
      remote_storage_server = Prog::Storage::RemoteStorageServer::Nexus.assemble(volume.id).subject

      old_name = vm.name
      vm.update(name: "moving-to-#{remote_storage_server.ubid}")

      new_vm = Prog::Vm::Nexus.assemble(
        vm.public_key,
        vm.project_id,
        name: old_name,
        size: vm.display_size,
        unix_user: vm.unix_user,
        location_id: vm.location_id,
        boot_image: vm.boot_image,
        private_subnet_id: vm.user_nic.private_subnet_id,
        storage_volumes: [{
          size_gib: volume.size_gib,
          max_read_mbytes_per_sec: volume.max_read_mbytes_per_sec,
          max_write_mbytes_per_sec: volume.max_write_mbytes_per_sec,
          vring_workers: volume.vring_workers,
          encrypted: !volume.key_encryption_key_1_id.nil?,
          track_written: volume.track_written
        }],
        enable_ip4: vm.ip4_enabled,
        pool_id: vm.pool_id,
        arch: vm.arch,
        force_host_id: vm_host.id,
        remote_storage_server_id: remote_storage_server.id
      ).subject

      Strand.create(
        prog: "Vm::Metal::MoveVm",
        label: "start",
        stack: [{"subject_id" => new_vm.id, "remote_storage_server_id" => remote_storage_server.id}]
      )
    end
  end

  # Mirrors the core/memory/storage checks Scheduling::Allocator performs for
  # a dedicated (non-slice) allocation, so an unmovable request fails eagerly
  # here rather than napping forever in Prog::Vm::Metal::Nexus#start.
  def self.sufficient_space?(vm_host, vm, volume)
    cores_needed = [1, vm.vcpus * vm_host.total_cores / vm_host.total_cpus].max
    return false if vm_host.total_cores - vm_host.used_cores < cores_needed
    return false if vm_host.total_hugepages_1g - vm_host.used_hugepages_1g < vm.memory_gib

    vm_host.storage_devices.any? { it.available_storage_gib >= volume.size_gib }
  end

  def remote_storage_server
    @remote_storage_server ||= RemoteStorageServer[remote_storage_server_id]
  end

  label def start
    register_deadline("wait", 60 * 60)
    hop_wait
  end

  label def wait
    nap 30 unless vm.strand.label == "wait"
    nap 30 unless vm.vm_storage_volumes.first.caught_up?
    hop_destroy
  end

  label def destroy
    remote_storage_server.incr_destroy
    pop "vm moved"
  end
end
