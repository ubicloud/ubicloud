# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::VmPool < Prog::Base
  subject_is :vm_pool

  semaphore :destroy

  def self.assemble(size:, vm_size:, boot_image:, location:, storage_size_gib:,
    storage_encrypted:, storage_skip_sync:, arch:)
    DB.transaction do
      vm_pool = VmPool.create_with_id(
        size: size,
        vm_size: vm_size,
        boot_image: boot_image,
        location: location,
        storage_size_gib: storage_size_gib,
        storage_encrypted: storage_encrypted,
        storage_skip_sync: storage_skip_sync,
        arch: arch
      )
      Strand.create(prog: "Vm::VmPool", label: "create_new_vm") { _1.id = vm_pool.id }
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_vms_destroy"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def create_new_vm
    storage_params = {
      size_gib: vm_pool.storage_size_gib,
      encrypted: vm_pool.storage_encrypted,
      skip_sync: vm_pool.storage_skip_sync
    }
    ps = Prog::Vnet::SubnetNexus.assemble(
      Config.vm_pool_project_id,
      location: vm_pool.location,
      allow_only_ssh: true
    ).subject

    Prog::Vm::Nexus.assemble_with_sshable(
      "runneradmin",
      Config.vm_pool_project_id,
      size: vm_pool.vm_size,
      location: vm_pool.location,
      boot_image: vm_pool.boot_image,
      storage_volumes: [storage_params],
      enable_ip4: true,
      pool_id: vm_pool.id,
      arch: vm_pool.arch,
      allow_only_ssh: true,
      swap_size_bytes: 4294963200,
      private_subnet_id: ps.id
    )

    hop_wait
  end

  label def wait
    if (need_vm = vm_pool.size - vm_pool.vms.count) > 0
      # Here we are trying to figure out the system's overall need for VMs at the
      # moment. We don't want to provision a VM if there are already too many
      # waiting to be provisioned for other github runners.
      vm_waiting_runners = GithubRunner.join(:strand, id: :id).where(Sequel[:strand][:label] => "wait_vm").count
      hop_create_new_vm if need_vm - vm_waiting_runners > 0
    end
    nap 30
  end

  label def destroy
    vm_pool.vms.each do |vm|
      vm.private_subnets.each { _1.incr_destroy }
      vm.incr_destroy
    end
    hop_wait_vms_destroy
  end

  label def wait_vms_destroy
    nap 10 if vm_pool.vms.count > 0

    vm_pool.destroy
    pop "pool destroyed"
  end
end
