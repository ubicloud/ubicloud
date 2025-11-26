# frozen_string_literal: true

require "json"
require "shellwords"

class Prog::Vm::Metal::Nexus < Prog::Base
  DEFAULT_SIZE = "standard-2"

  subject_is :vm

  def vm_name
    @vm_name ||= vm.inhost_name
  end

  def q_vm
    vm_name.shellescape
  end

  def vm_home
    File.join("", "vm", vm_name)
  end

  def host
    @host ||= vm.vm_host
  end

  def params_path
    @params_path ||= File.join(vm_home, "prep.json")
  end

  def clear_stack_storage_volumes
    current_frame = strand.stack.first
    current_frame.delete("storage_volumes")
    strand.modified!(:stack)
    strand.save_changes
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "remove_vm_from_load_balancer", "wait_vm_removal_from_load_balancer", "destroy_slice"].include? strand.label
        vm.active_billing_records.each(&:finalize)
        vm.assigned_vm_address&.active_billing_record&.finalize
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def start
    queued_vms = Vm.join(:strand, id: :id).where(:location_id => vm.location_id, :arch => vm.arch, Sequel[:strand][:label] => "start")
    begin
      distinct_storage_devices = frame["distinct_storage_devices"] || false
      host_exclusion_filter = frame["exclude_host_ids"] || []
      gpu_count = frame["gpu_count"] || 0
      gpu_device = frame["gpu_device"] || nil
      runner = GithubRunner.first(vm_id: vm.id) if vm.location_id == Location::GITHUB_RUNNERS_ID
      allocation_state_filter, location_filter, location_preference, host_filter, family_filter =
        if frame["force_host_id"]
          [[], [], [], [frame["force_host_id"]], []]
        elsif vm.location_id == Location::GITHUB_RUNNERS_ID
          runner_location_filter = [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID]
          runner_location_preference = [Location::GITHUB_RUNNERS_ID]
          installation = runner&.installation
          prefs = installation&.allocator_preferences || {}

          runner_family_filter = if runner&.not_upgrade_premium_set? || vm.family == "premium" || vm.family == "standard-gpu"
            [vm.family]
          elsif installation&.free_runner_upgrade?
            prefs["family_filter"] || [vm.family, "premium"]
          else
            prefs["family_filter"] || [vm.family]
          end
          [
            ["accepting"],
            prefs["location_filter"] || runner_location_filter,
            prefs["location_preference"] || runner_location_preference,
            [],
            runner_family_filter
          ]
        else
          [["accepting"], [vm.location_id], [], [], [vm.family]]
        end
      family_filter = ["standard"] if vm.family == "burstable"

      Scheduling::Allocator.allocate(
        vm, frame["storage_volumes"],
        distinct_storage_devices: distinct_storage_devices,
        allocation_state_filter: allocation_state_filter,
        location_filter: location_filter,
        location_preference: location_preference,
        host_filter: host_filter,
        host_exclusion_filter: host_exclusion_filter,
        gpu_count: gpu_count,
        gpu_device: gpu_device,
        family_filter: family_filter
      )
    rescue RuntimeError => ex
      raise unless ex.message.include?("no space left on any eligible host")

      incr_waiting_for_capacity unless vm.waiting_for_capacity_set?

      Clog.emit("No capacity left") { {lack_of_capacity: {location: Location[vm.location_id].name, arch: vm.arch, family: vm.family, queue_size: queued_vms.count}} }

      unless Location[vm.location_id].name == "github-runners" && vm.created_at > Time.now - 60 * 60
        utilization = VmHost.where(allocation_state: "accepting", arch: vm.arch).select_map { sum(:used_cores) * 100.0 / sum(:total_cores) }.first.to_f
        Prog::PageNexus.assemble("No capacity left at #{Location[vm.location_id].display_name} for #{vm.family} family of #{vm.arch}", ["NoCapacity", Location[vm.location_id].display_name, vm.arch, vm.family], queued_vms.limit(25).select_map(Sequel[:vm][:id]).map { UBID.from_uuidish(it).to_s }, extra_data: {queue_size: queued_vms.count, utilization: utilization})
      end

      nap 30
    end

    vm.nics.each(&:incr_vm_allocated)
    decr_waiting_for_capacity
    if (page = Page.from_tag_parts("NoCapacity", vm.location.display_name, vm.arch, vm.family)) && page.created_at < Time.now - 15 * 60 && queued_vms.count <= 1
      page.incr_resolve
    end

    register_deadline("wait", 10 * 60)

    # We don't need storage_volume info anymore, so delete it before
    # transitioning to the next state.
    clear_stack_storage_volumes

    hop_create_unix_user
  end

  label def create_unix_user
    uid = rand(1100..59999)
    command = <<~COMMAND
      set -ueo pipefail
      # Make this script idempotent
      sudo userdel --remove --force #{q_vm} || true
      sudo groupdel -f #{q_vm} || true
      # Create vm's user and home directory
      sudo adduser --disabled-password --gecos '' --home #{vm_home.shellescape} --uid #{uid} #{q_vm}
      # Enable KVM access for VM user
      sudo usermod -a -G kvm #{q_vm}
    COMMAND

    host.sshable.cmd(command)

    hop_prep
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{q_vm}")
    when "Succeeded"
      vm.nics.each(&:incr_setup_nic)
      strand.stack[-1]["prep_done"] = true
      strand.modified!(:stack)
      hop_clean_prep
    when "NotStarted", "Failed"
      secrets_json = JSON.generate({
        storage: vm.storage_secrets
      })

      write_params_json

      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-vm prep #{q_vm}' prep_#{q_vm}", stdin: secrets_json)
    end

    nap 1
  end

  label def clean_prep
    host.sshable.cmd("common/bin/daemonizer --clean prep_#{q_vm}")
    hop_wait_sshable
  end

  def write_params_json
    host.sshable.cmd("sudo -u #{q_vm} tee #{params_path.shellescape} > /dev/null",
      stdin: vm.params_json(**frame.slice("swap_size_bytes", "hugepages", "hypervisor", "ch_version", "firmware_version").transform_keys!(&:to_sym)))
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      # This is the first time we get into this state and we know that
      # wait_sshable will take definitely more than 6 seconds. So, we nap here
      # to reduce the amount of load on the control plane unnecessarily.
      nap 6
    end
    addr = vm.ip4
    hop_create_billing_record unless addr

    begin
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    hop_create_billing_record
  end

  label def create_billing_record
    vm.update(display_state: "running", provisioned_at: Time.now)

    Clog.emit("vm provisioned") { [vm, {provision: {vm_ubid: vm.ubid, vm_host_ubid: host.ubid, duration: (Time.now - vm.allocated_at).round(3)}}] }

    project = vm.project
    strand.stack[-1]["create_billing_record_done"] = true
    strand.modified!(:stack)
    hop_wait unless project.billable

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus
    )

    vm.storage_volumes.each do |vol|
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: "Disk ##{vol["disk_index"]} of #{vm.name}",
        billing_rate_id: BillingRate.from_resource_properties("VmStorage", vm.family, vm.location.name)["id"],
        amount: vol["size_gib"]
      )
    end

    if vm.ip4_enabled
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location.name)["id"],
        amount: 1
      )
    end

    if vm.pci_devices.any? { |dev| dev.is_gpu }
      gpu_count = vm.pci_devices.count { |dev| dev.is_gpu }
      gpu = vm.pci_devices.find { |dev| dev.is_gpu }

      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: "GPUs of #{vm.name}",
        billing_rate_id: BillingRate.from_resource_properties("Gpu", gpu.device, vm.location.name)["id"],
        amount: gpu_count
      )
    end

    hop_wait
  end

  label def wait
    when_start_after_host_reboot_set? do
      register_deadline("wait", 5 * 60)
      hop_start_after_host_reboot
    end

    when_update_firewall_rules_set? do
      register_deadline("wait", 5 * 60)
      hop_update_firewall_rules
    end

    when_update_spdk_dependency_set? do
      register_deadline("wait", 5 * 60)
      hop_update_spdk_dependency
    end

    when_restart_set? do
      register_deadline("wait", 5 * 60)
      hop_restart
    end

    when_stop_set? do
      hop_stopped
    end

    when_checkup_set? do
      hop_unavailable if !available?
      decr_checkup
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. We still
      # go to the unavailable state for keeping track of the state.
      hop_unavailable
    end

    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    if retval&.dig("msg") == "firewall rule is added"
      hop_wait
    end

    decr_update_firewall_rules
    push vm.update_firewall_rules_prog, {}, :update_firewall_rules
  end

  label def update_spdk_dependency
    decr_update_spdk_dependency
    write_params_json
    host.sshable.cmd("sudo host/bin/setup-vm reinstall-systemd-units #{q_vm}")
    hop_wait
  end

  label def restart
    decr_restart
    host.sshable.cmd("sudo host/bin/setup-vm restart #{q_vm}")
    hop_wait
  end

  label def stopped
    when_stop_set? do
      host.sshable.cmd("sudo systemctl stop #{q_vm}")
    end
    decr_stop

    nap 60 * 60
  end

  label def unavailable
    # If the VM become unavailable due to host unavailability, it first needs to
    # go through start_after_host_reboot state to be able to recover.
    when_start_after_host_reboot_set? do
      incr_checkup
      hop_start_after_host_reboot
    end

    begin
      if available?
        decr_checkup
        hop_wait
      else
        # Use deadlines to create a page instead of a custom page, so page
        # resolution in different states can be handled properly.
        register_deadline("wait", 0)
      end
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. No need
      # to create a page for this case.
    end

    nap 30
  end

  label def prevent_destroy
    register_deadline("destroy", 24 * 60 * 60)
    nap 30
  end

  label def destroy
    decr_destroy

    when_prevent_destroy_set? do
      Clog.emit("Destroy prevented by the semaphore")
      hop_prevent_destroy
    end

    vm.update(display_state: "deleting")

    unless host.nil?
      begin
        host.sshable.cmd("sudo systemctl stop #{q_vm}", timeout: 10)
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.stderr)
      end

      begin
        host.sshable.cmd("sudo systemctl stop #{q_vm}-dnsmasq")
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.stderr)
      end

      # If there is a load balancer setup, we want to keep the network setup in
      # tact for a while
      action = vm.load_balancer ? "delete_keep_net" : "delete"
      host.sshable.cmd("sudo host/bin/setup-vm #{action} #{q_vm}")
    end

    vm.vm_storage_volumes.each do |vol|
      vol.storage_device_dataset.update(available_storage_gib: Sequel[:available_storage_gib] + vol.size_gib)
    end

    if vm.vm_host_slice
      # If the vm is running in a slice, the slice deallocation will update cpu and memory on the host
      # Instead update the slice utilization
      VmHostSlice.dataset.where(id: vm.vm_host_slice_id).update(
        used_cpu_percent: Sequel[:used_cpu_percent] - vm.cpu_percent_limit,
        used_memory_gib: Sequel[:used_memory_gib] - vm.memory_gib
      )
    elsif host
      fail "BUG: Number of cores cannot be zero when VM is runing without a slice" if vm.cores == 0

      # If there is no slice, we need to update the host utilization directly
      VmHost.dataset.where(id: vm.vm_host_id).update(
        used_cores: Sequel[:used_cores] - vm.cores,
        used_hugepages_1g: Sequel[:used_hugepages_1g] - vm.memory_gib
      )
    end

    vm.pci_devices_dataset.update(vm_id: nil)
    vm.gpu_partition_dataset.update(vm_id: nil)

    hop_remove_vm_from_load_balancer if vm.load_balancer

    hop_destroy_slice
  end

  label def remove_vm_from_load_balancer
    bud Prog::Vnet::LoadBalancerRemoveVm, {"subject_id" => vm.id}, :mark_vm_ports_as_evacuating
    hop_wait_vm_removal_from_load_balancer
  end

  label def wait_vm_removal_from_load_balancer
    reap(nap: 10) do
      host&.sshable&.cmd("sudo host/bin/setup-vm delete_net #{q_vm}")
      hop_destroy_slice
    end
  end

  label def destroy_slice
    slice = vm.vm_host_slice

    # Remove the VM before we destroy the slice
    final_clean_up

    # Trigger the slice deletion if there are no
    # VMs using it.
    # We do not need to wait for this to complete
    #
    # We disable the slice to prevent another
    # concurrent VM allocation from grabbing it
    # while it is being destroyed and we check if
    # the operation succeeded in case some other
    # transaction took over this slice.
    if slice
      updated = slice.this
        .where(enabled: true, used_cpu_percent: 0, used_memory_gib: 0)
        .update(enabled: false)

      if updated == 1
        slice.incr_destroy
      end
    end

    pop "vm deleted"
  end

  def final_clean_up
    vm.nics.map do |nic|
      nic.update(vm_id: nil)
      nic.incr_destroy
    end
    vm.destroy
  end

  label def start_after_host_reboot
    vm.update(display_state: "starting")

    secrets_json = JSON.generate({
      storage: vm.storage_secrets
    })

    host.sshable.cmd("sudo host/bin/setup-vm recreate-unpersisted #{q_vm}", stdin: secrets_json)
    vm.nics.each(&:incr_repopulate)

    vm.update(display_state: "running")

    decr_start_after_host_reboot

    vm.incr_update_firewall_rules
    hop_wait
  end

  def available?
    host.sshable.cmd("systemctl is-active #{vm.inhost_name} #{vm.inhost_name}-dnsmasq").split("\n").all?("active")
  end
end
