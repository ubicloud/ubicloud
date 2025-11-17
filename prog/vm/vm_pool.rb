# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::VmPool < Prog::Base
  subject_is :vm_pool

  def self.assemble(size:, vm_size:, boot_image:, location_id:, storage_size_gib:,
    storage_encrypted:, storage_skip_sync:, arch:)
    DB.transaction do
      vm_pool = VmPool.create(
        size:,
        vm_size:,
        boot_image:,
        location_id:,
        storage_size_gib:,
        storage_encrypted:,
        storage_skip_sync:,
        arch:
      )
      Strand.create_with_id(vm_pool, prog: "Vm::VmPool", label: "create_new_vm")
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
    # Create a firewall with SSH-only access for VM pool
    project = Project[Config.vm_pool_project_id]
    location = Location[vm_pool.location_id]
    firewall_name = "vm-pool-#{location.name}-firewall"
    firewall = project.firewalls_dataset.first(location_id: vm_pool.location_id, name: firewall_name)
    unless firewall
      firewall = Firewall.create(name: firewall_name, location_id: vm_pool.location_id, project_id: Config.vm_pool_project_id)
      DB.ignore_duplicate_queries do
        ["0.0.0.0/0", "::/0"].each do |cidr|
          FirewallRule.create(firewall_id: firewall.id, cidr: cidr, port_range: Sequel.pg_range(22..22))
        end
      end
    end

    ps = Prog::Vnet::SubnetNexus.assemble(
      Config.vm_pool_project_id,
      location_id: vm_pool.location_id,
      firewall_id: firewall.id
    ).subject

    Prog::Vm::Nexus.assemble_with_sshable(
      Config.vm_pool_project_id,
      unix_user: "runneradmin",
      sshable_unix_user: "runneradmin",
      size: vm_pool.vm_size,
      location_id: vm_pool.location_id,
      boot_image: vm_pool.boot_image,
      storage_volumes: [storage_params],
      enable_ip4: true,
      pool_id: vm_pool.id,
      arch: vm_pool.arch,
      swap_size_bytes: 4294963200,
      private_subnet_id: ps.id
    )

    hop_wait
  end

  label def wait
    if vm_pool.size - vm_pool.vms.count > 0
      idle_cpus = VmHost.where(allocation_state: "accepting", arch: vm_pool.arch, location_id: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_HEL1_ID, Location::HETZNER_FSN1_ID]).select_map { sum((total_cores - used_cores) * total_cpus / total_cores) }.first.to_i
      waiting_cpus = Vm.where(Sequel.like(:boot_image, "github%")).where(allocated_at: nil, arch: vm_pool.arch).sum(:vcpus).to_i
      pool_vm_cpus = Validation.validate_vm_size(vm_pool.vm_size, vm_pool.arch).vcpus
      hop_create_new_vm if idle_cpus - waiting_cpus - pool_vm_cpus >= 0
    end
    nap 30
  end

  label def destroy
    vm_pool.vms.each do |vm|
      vm.private_subnets.each { it.incr_destroy }
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
