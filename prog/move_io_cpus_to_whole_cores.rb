# frozen_string_literal: true

class Prog::MoveIoCpusToWholeCores < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    fail "No existing VmHost" unless (vm_host = VmHost[vm_host_id])
    fail "VmHost has cpus without a core number" unless vm_host.cpus_dataset.where(core_number: nil).empty?

    Strand.create(prog: "MoveIoCpusToWholeCores", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  def io_core_numbers
    0...(vm_host.io_cpu_count * vm_host.total_cores / vm_host.total_cpus)
  end

  def target_cpus
    vm_host.cpus_dataset.where(core_number: io_core_numbers)
  end

  label def start
    pop "VmHost does not accept slices, so its io cpus need no change" unless vm_host.accepts_slices
    pop "VmHost runs SPDK, whose reactors are pinned to the old io cpus, so its io cpus are left as they are" unless vm_host.spdk_installations_dataset.empty?

    hop_move_io_cpus
  end

  label def move_io_cpus
    nap 30 if target_cpus.for_update.select_map(:vm_host_slice_id).any?
    nap 30 unless vm_host.vms_dataset.where(display_state: "creating").exclude(vm_host_slice_id: nil).empty?

    target_cpus.update(io: true)
    vm_host.cpus_dataset.where(io: true).exclude(core_number: io_core_numbers).update(io: false)
    hop_update_storage_daemons
  end

  label def update_storage_daemons
    io_cpus = vm_host.cpus_dataset.where(io: true).select_map(:cpu_number)
    vms = vm_host.vms_dataset.exclude(display_state: %w[creating deleting]).exclude(vm_host_slice_id: nil).eager(:vm_storage_volumes, vm_host_slice: :cpus).all

    commands = vms.flat_map do |vm|
      allowed_cpus = (vm.vm_host_slice.cpus.map(&:cpu_number) + io_cpus).sort!.join(",")
      vm.vm_storage_volumes.select(&:vhost_block_backend_id).map do |sv|
        NetSsh.command("sudo systemctl set-property :unit AllowedCPUs=:allowed_cpus", unit: sv.vhost_backend_systemd_unit_name, allowed_cpus:)
      end
    end
    sshable.cmd(NetSsh.combine(*commands, joiner: " && ")) unless commands.empty?

    pop "moved io cpus to whole cores"
  end
end
