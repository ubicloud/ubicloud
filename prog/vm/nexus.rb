# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::Vm::Nexus < Prog::Base
  DEFAULT_SIZE = "standard-2"

  subject_is :vm

  def self.assemble(public_key, project_id, name: nil, size: DEFAULT_SIZE,
    unix_user: "ubi", location_id: Location::HETZNER_FSN1_ID, boot_image: Config.default_boot_image_name,
    private_subnet_id: nil, nic_id: nil, storage_volumes: nil, boot_disk_index: 0,
    enable_ip4: false, pool_id: nil, arch: "x64", swap_size_bytes: nil,
    distinct_storage_devices: false, force_host_id: nil, exclude_host_ids: [], gpu_count: 0, gpu_device: nil,
    hugepages: true, ch_version: nil, firmware_version: nil)

    unless (project = Project[project_id])
      fail "No existing project"
    end
    if exclude_host_ids.include?(force_host_id)
      fail "Cannot force and exclude the same host"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    vm_size = Validation.validate_vm_size(size, arch)
    Validation.validate_billing_rate("VmVCpu", vm_size.family, location.name)

    storage_volumes ||= [{
      size_gib: vm_size.storage_size_options.first,
      encrypted: true
    }]

    # allow missing fields to make testing during development more convenient.
    storage_volumes.each_with_index do |volume, disk_index|
      volume[:size_gib] ||= vm_size.storage_size_options.first
      volume[:skip_sync] ||= false
      volume[:max_read_mbytes_per_sec] ||= vm_size.io_limits.max_read_mbytes_per_sec
      volume[:max_write_mbytes_per_sec] ||= vm_size.io_limits.max_write_mbytes_per_sec
      volume[:encrypted] = true if !volume.has_key? :encrypted
      volume[:boot] = disk_index == boot_disk_index

      if volume[:read_only]
        volume[:size_gib] = 0
        volume[:encrypted] = false
        volume[:skip_sync] = true
        volume[:boot] = false
      end
    end

    Validation.validate_storage_volumes(storage_volumes, boot_disk_index)

    ubid = Vm.generate_ubid
    name ||= Vm.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_os_user_name(unix_user)

    DB.transaction do
      # Here the logic is the following;
      # - If the user provided nic_id, that nic has to exist and we fetch private_subnet
      # from the reference of nic. We just assume it and not even check the validity of the
      # private_subnet_id.
      # - If the user did not provide nic_id but the private_subnet_id, that private_subnet
      # must exist, otherwise we fail.
      # - If the user did not provide nic_id but the private_subnet_id and that subnet exists
      # then we create a nic on that subnet.
      # - If the user provided neither nic_id nor private_subnet_id, that's OK, we create both.
      nic = nil
      subnet = if nic_id
        nic = Nic[nic_id]
        raise("Given nic doesn't exist with the id #{nic_id}") unless nic
        raise("Given nic is assigned to a VM already") if nic.vm_id
        raise("Given nic is created in a different location") if nic.private_subnet.location_id != location.id
        raise("Given nic is not available in the given project") unless project.private_subnets.any? { |ps| ps.id == nic.private_subnet_id }

        nic.private_subnet
      end

      unless nic
        subnet = if private_subnet_id
          subnet = PrivateSubnet[private_subnet_id]
          raise "Given subnet doesn't exist with the id #{private_subnet_id}" unless subnet
          raise "Given subnet is not available in the given project" unless project.private_subnets.any? { |ps| ps.id == subnet.id }
          subnet
        else
          project.default_private_subnet(location)
        end
        nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{name}-nic").subject
      end

      vm = Vm.create(
        public_key: public_key,
        unix_user: unix_user,
        name: name,
        family: vm_size.family,
        cores: 0, # this will be updated after allocation is complete based on the host's topology
        vcpus: vm_size.vcpus,
        cpu_percent_limit: vm_size.cpu_percent_limit,
        cpu_burst_percent_limit: vm_size.cpu_burst_percent_limit,
        memory_gib: vm_size.memory_gib,
        location_id: location.id,
        boot_image: boot_image,
        ip4_enabled: enable_ip4,
        pool_id: pool_id,
        arch: arch,
        project_id:
      ) { it.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      if vm_size.family == "standard-gpu"
        gpu_count = 1
        gpu_device = "27b0"
      end

      label = if location.aws?
        disk_index = 0
        storage_volumes.each do |volume|
          disk_count = (volume[:size_gib] == 3800) ? 2 : 1

          disk_count.times do
            VmStorageVolume.create_with_id(
              vm_id: vm.id,
              size_gib: volume[:size_gib] / disk_count,
              boot: volume[:boot],
              use_bdev_ubi: false,
              disk_index:
            )

            disk_index += 1
          end
        end
        "start_aws"
      else
        "start"
      end

      Strand.create(
        prog: "Vm::Nexus",
        label:,
        stack: [{
          "storage_volumes" => storage_volumes.map { |v| v.transform_keys(&:to_s) },
          "swap_size_bytes" => swap_size_bytes,
          "distinct_storage_devices" => distinct_storage_devices,
          "force_host_id" => force_host_id,
          "exclude_host_ids" => exclude_host_ids,
          "gpu_count" => gpu_count,
          "gpu_device" => gpu_device,
          "hugepages" => hugepages,
          "ch_version" => ch_version,
          "firmware_version" => firmware_version
        }]
      ) { it.id = vm.id }
    end
  end

  def self.assemble_with_sshable(*, sshable_unix_user: "rhizome", **kwargs)
    ssh_key = SshKey.generate
    st = assemble(ssh_key.public_key, *, **kwargs)
    Sshable.create(unix_user: sshable_unix_user, host: "temp_#{st.id}", raw_private_key_1: ssh_key.keypair) {
      it.id = st.id
    }
    st
  end

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
      unless ["destroy", "wait_lb_expiry", "destroy_slice"].include? strand.label
        vm.active_billing_records.each(&:finalize)
        vm.assigned_vm_address&.active_billing_record&.finalize
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def start_aws
    nap 5 unless vm.nics.all? { |nic| nic.strand.label == "wait" }
    bud Prog::Aws::Instance, {"subject_id" => vm.id}, :start
    hop_wait_aws_vm_started
  end

  label def wait_aws_vm_started
    reap(:wait_sshable, nap: 10)
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
          runner_family_filter = [vm.family]
          prefs = if runner
            runner_family_filter.append("premium") if runner.installation.free_runner_upgrade?
            runner.installation.allocator_preferences
          else
            {}
          end
          [
            ["accepting"],
            prefs["location_filter"] || runner_location_filter,
            prefs["location_preference"] || runner_location_preference,
            [],
            (vm.family == "premium" && [vm.family]) || prefs["family_filter"] || runner_family_filter
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
      queued_vms = queued_vms.all
      utilization = VmHost.where(allocation_state: "accepting", arch: vm.arch).select_map { sum(:used_cores) * 100.0 / sum(:total_cores) }.first.to_f
      Clog.emit("No capacity left") { {lack_of_capacity: {location: Location[vm.location_id].name, arch: vm.arch, family: vm.family, queue_size: queued_vms.count}} }

      unless Location[vm.location_id].name == "github-runners" && vm.created_at > Time.now - 60 * 60
        Prog::PageNexus.assemble("No capacity left at #{Location[vm.location_id].display_name} for #{vm.family} family of #{vm.arch}", ["NoCapacity", Location[vm.location_id].display_name, vm.arch, vm.family], queued_vms.first(25).map(&:ubid), extra_data: {queue_size: queued_vms.count, utilization: utilization})
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
    host.sshable.cmd("sudo -u #{q_vm} tee #{params_path.shellescape}",
      stdin: vm.params_json(**frame.slice("swap_size_bytes", "hugepages", "ch_version", "firmware_version").transform_keys!(&:to_sym)))
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      # This is the first time we get into this state and we know that
      # wait_sshable will take definitely more than 8 seconds. So, we nap here
      # to reduce the amount of load on the control plane unnecessarily.
      nap 8
    end
    addr = vm.ephemeral_net4
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

    Clog.emit("vm provisioned") { [vm, {provision: {vm_ubid: vm.ubid, vm_host_ubid: host&.ubid, duration: Time.now - vm.allocated_at}}] }

    project = vm.project
    hop_wait unless project.billable

    BillingRecord.create_with_id(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus
    )

    unless vm.location.aws?
      vm.storage_volumes.each do |vol|
        BillingRecord.create_with_id(
          project_id: project.id,
          resource_id: vm.id,
          resource_name: "Disk ##{vol["disk_index"]} of #{vm.name}",
          billing_rate_id: BillingRate.from_resource_properties("VmStorage", vm.family, vm.location.name)["id"],
          amount: vol["size_gib"]
        )
      end

      if vm.ip4_enabled
        BillingRecord.create_with_id(
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

        BillingRecord.create_with_id(
          project_id: project.id,
          resource_id: vm.id,
          resource_name: "GPUs of #{vm.name}",
          billing_rate_id: BillingRate.from_resource_properties("Gpu", gpu.device, vm.location.name)["id"],
          amount: gpu_count
        )
      end
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
    push Prog::Vnet::UpdateFirewallRules, {}, :update_firewall_rules
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
    if vm.location.aws?
      strand.children.select { it.prog == "Aws::Instance" }.each { it.destroy }
      bud Prog::Aws::Instance, {"subject_id" => vm.id}, :destroy
      hop_wait_aws_vm_destroyed
    end

    unless host.nil?
      begin
        host.sshable.cmd("sudo timeout 10s systemctl stop #{q_vm}")
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

    hop_wait_lb_expiry if vm.load_balancer

    hop_destroy_slice
  end

  label def wait_aws_vm_destroyed
    reap(nap: 10) do
      final_clean_up
      pop "vm deleted"
    end
  end

  label def wait_lb_expiry
    if (lb = vm.load_balancer)
      unless vm.lb_expiry_started_set?
        vm.incr_lb_expiry_started
        lb.evacuate_vm(vm)
        nap 30
      end
      lb.remove_vm(vm)
    end

    vm.vm_host.sshable.cmd("sudo host/bin/setup-vm delete_net #{q_vm}")

    hop_destroy_slice
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
