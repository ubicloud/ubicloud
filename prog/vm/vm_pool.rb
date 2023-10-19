# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::VmPool < Prog::Base
  subject_is :vm_pool

  semaphore :destroy

  def self.assemble(size:, vm_size:, boot_image:, location:)
    DB.transaction do
      vm_pool = VmPool.create_with_id(
        size: size,
        vm_size: vm_size,
        boot_image: boot_image,
        location: location
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
    ssh_key = SshKey.generate
    DB.transaction do
      vm_st = Prog::Vm::Nexus.assemble(
        ssh_key.public_key,
        Config.vm_pool_project_id,
        size: vm_pool.vm_size,
        unix_user: "runner",
        location: vm_pool.location,
        boot_image: vm_pool.boot_image,
        storage_volumes: [{size_gib: 86, encrypted: false}],
        enable_ip4: true,
        pool_id: vm_pool.id
      )
      Sshable.create(
        unix_user: "runner",
        host: "temp_#{vm_st.id}",
        raw_private_key_1: ssh_key.keypair
      ) { _1.id = vm_st.id }
    end

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
