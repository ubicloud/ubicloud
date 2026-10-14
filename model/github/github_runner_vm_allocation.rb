# frozen_string_literal: true

require_relative "../../model"

# The host resources (slice, storage and IPv4 address) of a destroyed runner
# VM, held for a short time so a new runner VM with the same label can reuse
# them without going through Scheduling::Allocator. The destroyed VM row is
# kept until the resources are reused or released, as the resources are still
# attached to it.
class GithubRunnerVmAllocation < Sequel::Model
  unrestrict_primary_key

  many_to_one :vm, read_only: true
  many_to_one :vm_host, read_only: true

  # Returns the runner label for the VM's configuration, or nil if the
  # resources of the VM cannot or should not be reused.
  def self.label_for(vm, storage_sizes)
    return unless storage_sizes.one?
    return unless [Config.github_runner_service_project_id, Config.vm_pool_project_id].include?(vm.project_id)
    return unless rand < Config.github_runner_vm_allocation_ratio

    Github.runner_label_for(family: vm.family, vcpus: vm.vcpus, arch: vm.arch, boot_image: vm.boot_image, storage_size_gib: storage_sizes.first)
  end

  # Moves the resources of a held VM with the same label to the given VM.
  # Returns whether held resources were found and reused.
  def self.claim(vm, storage_volumes)
    return false unless (label = label_for(vm, storage_volumes.map { it["size_gib"] }))

    allocation = where(label:, location_id: vm.location_id)
      .where(vm_host_id: VmHost.where(allocation_state: "accepting").select(:id))
      .order(:created_at)
      .for_update
      .skip_locked
      .first
    return false unless allocation

    allocation.reuse_for(vm, storage_volumes)
    true
  end

  def self.release_expired
    where { created_at < Sequel::CURRENT_TIMESTAMP - Sequel.cast("1 minute", :interval) }
      .or(vm_host_id: VmHost.exclude(allocation_state: "accepting").select(:id))
      .for_update
      .skip_locked
      .all
      .each(&:release)
  end

  def reuse_for(new_vm, storage_volumes)
    old_vm = vm
    host = vm_host

    new_vm.set(
      vm_host_id: host.id,
      vm_host_slice_id: old_vm.vm_host_slice_id,
      ephemeral_net6: host.ip6_random_vm_network.to_s,
      local_vetho_ip: host.veth_pair_random_ip4_addr,
      allocated_at: Time.now,
    )
    new_vm.save_with_ephemeral_net6_error_retrying(host)

    # Use a dataset update instead of the association, so that destroying the
    # old VM does not destroy the address through a cached association.
    AssignedVmAddress.where(dst_vm_id: old_vm.id).update(dst_vm_id: new_vm.id)
    new_vm.sshable.update(host: new_vm.ip4_string)

    Scheduling::Allocator::StorageAllocation.allocate_storage_volume_associations(
      new_vm, host,
      storage_volumes.each_with_index.to_h { |volume, disk_index| [disk_index, volume] },
      old_vm.vm_storage_volumes.to_h { [it.disk_index, it.storage_device_id] },
      Scheduling::Allocator.minimum_vhost_block_backend_version(storage_volumes),
    )

    destroy
    old_vm.destroy
    Clog.emit("vm allocation reused", {vm_allocation_reused: {vm: new_vm.ubid, previous_vm: old_vm.ubid, vm_host: host.ubid, label:, duration: Time.now - new_vm.created_at}})
  end

  # Returns the held resources to the host, by restarting the old VM's strand
  # at the point of its destroy where the resources are released.
  def release
    destroy
    Strand.create_with_id(vm_id, prog: "Vm::Metal::Nexus", label: "release_held_allocation")
    # Prevent the destroy semaphore from restarting the VM destroy, which
    # would release the resources a second time.
    Semaphore.incr(vm_id, :destroying, wake: false)
  end
end

# Table: github_runner_vm_allocation
# Columns:
#  vm_id       | uuid                     | PRIMARY KEY
#  label       | text                     | NOT NULL
#  location_id | uuid                     | NOT NULL
#  vm_host_id  | uuid                     | NOT NULL
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  github_runner_vm_allocation_pkey | PRIMARY KEY btree (vm_id)
# Foreign key constraints:
#  github_runner_vm_allocation_location_id_fkey | (location_id) REFERENCES location(id)
#  github_runner_vm_allocation_vm_host_id_fkey  | (vm_host_id) REFERENCES vm_host(id)
#  github_runner_vm_allocation_vm_id_fkey       | (vm_id) REFERENCES vm(id)
