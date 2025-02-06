# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::Vm::Nexus < Prog::Base
  subject_is :vm

  def self.assemble(public_key, project_id, name: nil, size: "standard-2",
    unix_user: "ubi", location: "hetzner-fsn1", boot_image: Config.default_boot_image_name,
    private_subnet_id: nil, nic_id: nil, storage_volumes: nil, boot_disk_index: 0,
    enable_ip4: false, pool_id: nil, arch: "x64", swap_size_bytes: nil,
    distinct_storage_devices: false, force_host_id: nil, exclude_host_ids: [], gpu_count: 0,
    ubid: nil, vm_size: nil, attempt: 1, strand: nil)

    unless (project = Project[project_id])
      fail "No existing project"
    end
    if exclude_host_ids.include?(force_host_id)
      fail "Cannot force and exclude the same host"
    end
    Validation.validate_location(location)
    vm_size ||= Validation.validate_vm_size(size, arch)

    assemble_storage_volumes = storage_volumes
    storage_volumes ||= [{
      size_gib: vm_size.storage_size_options.first,
      encrypted: true
    }]

    # allow missing fields to make testing during development more convenient.
    storage_volumes.each_with_index do |volume, disk_index|
      volume[:size_gib] ||= vm_size.storage_size_options.first
      volume[:skip_sync] ||= false
      volume[:max_ios_per_sec] ||= vm_size.io_limits.max_ios_per_sec
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

    ubid ||= Vm.generate_ubid
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
        raise("Given nic is created in a different location") if nic.private_subnet.location != location
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
        location: location,
        boot_image: boot_image,
        ip4_enabled: enable_ip4,
        pool_id: pool_id,
        arch: arch,
        project_id:
      ) { _1.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      gpu_count = 1 if gpu_count == 0 && vm_size.gpu

      strand ||= Strand.new { _1.id = vm.id }
      frame = strand.stack[-1] || {}
      strand.update(
        prog: "Vm::Nexus",
        label: "start",
        stack: [frame.merge(
          "assemble_storage_volumes" => assemble_storage_volumes,
          "storage_volumes" => storage_volumes.map { |v| v.transform_keys(&:to_s) },
          "swap_size_bytes" => swap_size_bytes,
          "distinct_storage_devices" => distinct_storage_devices,
          "force_host_id" => force_host_id,
          "exclude_host_ids" => exclude_host_ids,
          "private_subnet_id" => private_subnet_id,
          "nic_id" => nic_id,
          "pool_id" => pool_id,
          "attempt" => attempt,
          "gpu_count" => gpu_count
        )]
      )
    end
  end

  def self.assemble_with_sshable(unix_user, *, **kwargs)
    ssh_key = SshKey.generate
    kwargs[:unix_user] = unix_user
    st = assemble(ssh_key.public_key, *, **kwargs)
    Sshable.create(unix_user: unix_user, host: "temp_#{st.id}", raw_private_key_1: ssh_key.keypair) {
      _1.id = st.id
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
      if strand.label != "destroy"
        vm.active_billing_records.each(&:finalize)
        vm.assigned_vm_address&.active_billing_record&.finalize
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def start
    queued_vms = Vm.join(:strand, id: :id).where(:location => vm.location, :arch => vm.arch, Sequel[:strand][:label] => "start")
    begin
      distinct_storage_devices = frame["distinct_storage_devices"] || false
      host_exclusion_filter = frame["exclude_host_ids"] || []
      gpu_count = frame["gpu_count"] || 0
      allocation_state_filter, location_filter, location_preference, host_filter =
        if frame["force_host_id"]
          [[], [], [], [frame["force_host_id"]]]
        elsif vm.location == "github-runners"
          runner_locations = (vm.vcpus == 60) ? [] : ["github-runners", "hetzner-fsn1", "hetzner-hel1"]
          [["accepting"], runner_locations, ["github-runners"], []]
        else
          [["accepting"], [vm.location], [], []]
        end

      Scheduling::Allocator.allocate(
        vm, frame["storage_volumes"],
        distinct_storage_devices: distinct_storage_devices,
        allocation_state_filter: allocation_state_filter,
        location_filter: location_filter,
        location_preference: location_preference,
        host_filter: host_filter,
        host_exclusion_filter: host_exclusion_filter,
        gpu_count: gpu_count
      )
    rescue RuntimeError => ex
      raise unless ex.message.include?("no space left on any eligible host")

      incr_waiting_for_capacity unless vm.waiting_for_capacity_set?
      queued_vms = queued_vms.all
      utilization = VmHost.where(allocation_state: "accepting", arch: vm.arch).select_map { sum(:used_cores) * 100.0 / sum(:total_cores) }.first.to_f
      Prog::PageNexus.assemble("No capacity left at #{vm.location} for #{vm.family} family of #{vm.arch}", ["NoCapacity", vm.location, vm.arch, vm.family], queued_vms.first(25).map(&:ubid), severity: "warning", extra_data: {queue_size: queued_vms.count, utilization: utilization})
      Clog.emit("No capacity left") { {lack_of_capacity: {location: vm.location, arch: vm.arch, family: vm.family, queue_size: queued_vms.count}} }

      nap 30
    end

    vm.nics.each(&:incr_vm_allocated)
    decr_waiting_for_capacity
    if (page = Page.from_tag_parts("NoCapacity", vm.location, vm.arch, vm.family)) && page.created_at < Time.now - 15 * 60 && queued_vms.count <= 1
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

    hop_wait_for_slice
  end

  label def wait_for_slice
    if vm.vm_host_slice
      if !vm.vm_host_slice.enabled
        # Just wait here until the slice creation is completed
        nap 1
      end
    end

    hop_prep
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{q_vm}")
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean prep_#{q_vm}")
      vm.private_subnets.each(&:incr_add_new_nic)
      # To simulate failure case in development:
      # if frame["attempt"] < 3
      #   Clog.emit("VM prep forced fail for #{vm.ubid}, attempt: #{frame["attempt"]}")
      #   incr_recreate
      #   hop_destroy
      # end
      hop_wait_sshable
    when "Failed"
      if frame["attempt"] >= 3
        Prog::PageNexus.assemble("VM prep has failed for #{vm.ubid} (attempt: #{frame["attempt"]}", ["VmPrepFailed", vm.ubid], vm.ubid)
        hop_prep_failed
      end
      incr_recreate
      hop_destroy
    when "NotStarted"
      secrets_json = JSON.generate({
        storage: vm.storage_secrets
      })

      write_params_json

      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-vm prep #{q_vm}' prep_#{q_vm}", stdin: secrets_json)
    end

    nap 1
  end

  def write_params_json
    host.sshable.cmd("sudo -u #{q_vm} tee #{params_path.shellescape}", stdin: vm.params_json(frame["swap_size_bytes"]))
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
    Clog.emit("vm provisioned") { [vm, {provision: {vm_ubid: vm.ubid, vm_host_ubid: host.ubid, duration: Time.now - vm.allocated_at}}] }
    project = vm.project
    hop_wait unless project.billable

    BillingRecord.create_with_id(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location)["id"],
      amount: vm.vcpus
    )

    vm.storage_volumes.each do |vol|
      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: "Disk ##{vol["disk_index"]} of #{vm.name}",
        billing_rate_id: BillingRate.from_resource_properties("VmStorage", vm.family, vm.location)["id"],
        amount: vol["size_gib"]
      )
    end

    if vm.ip4_enabled
      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location)["id"],
        amount: 1
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

    nap 30
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
    host.sshable.cmd("sudo systemctl restart #{vm.inhost_name}")
    hop_wait
  end

  label def stopped
    when_stop_set? do
      host.sshable.cmd("sudo systemctl stop #{vm.inhost_name}")
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
        Page.from_tag_parts("VmUnavailable", vm.ubid)&.incr_resolve
        decr_checkup
        hop_wait
      else
        Prog::PageNexus.assemble("#{vm} is unavailable", ["VmUnavailable", vm.ubid], vm.ubid)
      end
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. No need
      # to create a page for this case.
    end

    nap 30
  end

  label def prep_failed
    nap(5 * 60)
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

    DB.transaction do
      vm.vm_storage_volumes.each do |vol|
        vol.storage_device_dataset.update(available_storage_gib: Sequel[:available_storage_gib] + vol.size_gib)
      end

      if vm.vm_host_slice.nil?
        fail "BUG: Number of cores cannot be zero when VM is runing without a slice" if vm.cores == 0
        # If there is no slice, we need to update the host utilization directly
        VmHost.dataset.where(id: vm.vm_host_id).update(
          used_cores: Sequel[:used_cores] - vm.cores,
          used_hugepages_1g: Sequel[:used_hugepages_1g] - vm.memory_gib
        )
      else
        # If the vm is running in a slice, the slice deallocation will update cpu and memory on the host
        # Instead update the slice utilization
        VmHostSlice.dataset.where(id: vm.vm_host_slice_id).update(
          used_cpu_percent: Sequel[:used_cpu_percent] - vm.cpu_percent_limit,
          used_memory_gib: Sequel[:used_memory_gib] - vm.memory_gib
        )
      end

      vm.pci_devices_dataset.update(vm_id: nil)
    end

    hop_wait_lb_expiry if vm.load_balancer

    hop_destroy_slice
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
    skip_nic_destroy_for_id = nil

    when_recreate_set? do
      skip_nic_destroy_for_id = frame["nic_id"]
    end

    # Remove the VM before we destroy the slice
    final_clean_up(skip_nic_destroy_for_id:)

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

    when_recreate_set? do
      decr_recreate

      # This does not pass boot_index_id, as the information contained in it is
      # encoded in the storage_volumes argument.
      #
      # It's possible to add the VM's current host to exclude_host_ids, but that will
      # break cases where it is the only available host. Could extend the allocator
      # to prefer a different host without excluding it if we really want to try another
      # host.
      self.class.assemble(vm.public_key, vm.project_id, name: vm.name, vm_size: vm.vm_size,
        unix_user: vm.unix_user, location: vm.location, boot_image: vm.boot_image,
        enable_ip4: vm.ip4_enabled, arch: vm.arch, ubid: UBID.parse(vm.ubid),
        nic_id: frame["nic_id"],
        private_subnet_id: frame["private_subnet_id"],
        storage_volumes: frame["storage_volumes"]&.map { _1.transform_keys(&:to_sym) },
        distinct_storage_devices: frame["distinct_storage_devices"],
        swap_size_bytes: frame["swap_size_bytes"],
        pool_id: frame["pool_id"],
        gpu_count: frame["gpu_count"] || 0,
        force_host_id: frame["force_host_id"],
        exclude_host_ids: frame["exclude_host_ids"],
        attempt: frame["attempt"] + 1,
        strand:)

      hop_start
    end

    pop "vm deleted"
  end

  def final_clean_up(skip_nic_destroy_for_id: nil)
    vm.nics.map do |nic|
      nic.update(vm_id: nil)
      nic.incr_destroy unless nic.id == skip_nic_destroy_for_id
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
