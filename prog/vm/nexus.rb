# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::Vm::Nexus < Prog::Base
  subject_is :vm
  semaphore :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules, :checkup, :update_spdk_dependency

  def self.assemble(public_key, project_id, name: nil, size: "standard-2",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: Config.default_boot_image_name,
    private_subnet_id: nil, nic_id: nil, storage_volumes: nil, boot_disk_index: 0,
    enable_ip4: false, pool_id: nil, arch: "x64", allow_only_ssh: false, swap_size_bytes: nil,
    distinct_storage_devices: false, force_host_id: nil)

    unless (project = Project[project_id])
      fail "No existing project"
    end
    Validation.validate_location(location)
    vm_size = Validation.validate_vm_size(size)

    storage_volumes ||= [{
      size_gib: vm_size.storage_size_gib,
      encrypted: true
    }]

    # allow missing fields to make testing during development more convenient.
    storage_volumes.each_with_index do |volume, disk_index|
      volume[:size_gib] ||= vm_size.storage_size_gib
      volume[:skip_sync] ||= false
      volume[:encrypted] = true if !volume.has_key? :encrypted
      volume[:boot] = disk_index == boot_disk_index
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
      subnet = nil
      if nic_id
        nic = Nic[nic_id]
        raise("Given nic doesn't exist with the id #{nic_id}") unless nic
        raise("Given nic is assigned to a VM already") if nic.vm_id
        raise("Given nic is created in a different location") if nic.private_subnet.location != location
        raise("Given nic is not available in the given project") unless project.private_subnets.any? { |ps| ps.id == nic.private_subnet_id }

        subnet = nic.private_subnet
      end

      unless nic
        subnet = nil
        if private_subnet_id
          subnet = PrivateSubnet[private_subnet_id]
          raise "Given subnet doesn't exist with the id #{private_subnet_id}" unless subnet
          raise "Given subnet is not available in the given project" unless project.private_subnets.any? { |ps| ps.id == subnet.id }
        else
          subnet_s = Prog::Vnet::SubnetNexus.assemble(project_id, name: "#{name}-subnet", location: location, allow_only_ssh: allow_only_ssh)
          subnet = PrivateSubnet[subnet_s.id]
        end
        nic_s = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{name}-nic")
        nic = Nic[nic_s.id]
      end

      cores = if arch == "arm64"
        vm_size.vcpu
      else
        vm_size.vcpu / 2
      end

      vm = Vm.create(public_key: public_key, unix_user: unix_user,
        name: name, family: vm_size.family, cores: cores, location: location,
        boot_image: boot_image, ip4_enabled: enable_ip4, pool_id: pool_id, arch: arch) { _1.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      vm.associate_with_project(project)

      Strand.create(
        prog: "Vm::Nexus",
        label: "start",
        stack: [{
          "storage_volumes" => storage_volumes.map { |v| v.transform_keys(&:to_s) },
          "swap_size_bytes" => swap_size_bytes,
          "distinct_storage_devices" => distinct_storage_devices,
          "force_host_id" => force_host_id,
          "gpu_enabled" => vm_size.gpu
        }]
      ) { _1.id = vm.id }
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

  def local_ipv4
    vm.local_vetho_ip&.to_s&.shellescape || ""
  end

  def params_path
    @params_path ||= File.join(vm_home, "prep.json")
  end

  def storage_volumes
    @storage_volumes ||= vm.vm_storage_volumes.map { |s|
      {
        "boot" => s.boot,
        "image" => s.boot ? vm.boot_image : nil,
        "image_version" => s.boot_image&.version,
        "size_gib" => s.size_gib,
        "device_id" => s.device_id,
        "disk_index" => s.disk_index,
        "encrypted" => !s.key_encryption_key_1.nil?,
        "spdk_version" => s.spdk_version,
        "use_bdev_ubi" => s.use_bdev_ubi,
        "skip_sync" => s.skip_sync,
        "storage_device" => s.storage_device.name
      }
    }
  end

  def storage_secrets
    @storage_secrets ||= vm.vm_storage_volumes.filter_map { |s|
      if !s.key_encryption_key_1.nil?
        [s.device_id, s.key_encryption_key_1.secret_key_material_hash]
      end
    }.to_h
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
        vm.active_billing_record&.finalize
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
      gpu_enabled = frame["gpu_enabled"] || false
      allocation_state_filter, location_filter, location_preference, host_filter =
        if frame["force_host_id"]
          [[], [], [], [frame["force_host_id"]]]
        elsif vm.location == "github-runners"
          [["accepting"], [], ["github-runners"], []]
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
        gpu_enabled: gpu_enabled
      )
    rescue RuntimeError => ex
      raise unless ex.message.include?("no space left on any eligible host")

      queued_vms = queued_vms.all
      Prog::PageNexus.assemble("No capacity left at #{vm.location} for #{vm.arch}", queued_vms.first(25).map(&:ubid), "NoCapacity", vm.location, vm.arch)
      Clog.emit("No capacity left") { {lack_of_capacity: {location: vm.location, arch: vm.arch, queue_size: queued_vms.count}} }

      nap 30
    end

    if (page = Page.from_tag_parts("NoCapacity", vm.location, vm.arch)) && page.created_at < Time.now - 15 * 60 && queued_vms.count <= 1
      page.incr_resolve
    end

    register_deadline(:wait, 10 * 60)

    # We don't need storage_volume info anymore, so delete it before
    # transitioning to the next state.
    clear_stack_storage_volumes

    hop_create_unix_user
  end

  label def create_unix_user
    host.sshable.cmd("sudo userdel --remove --force #{q_vm} || true")
    host.sshable.cmd("sudo groupdel -f #{q_vm} || true")

    # create vm's user and home directory
    uid = rand(1100..59999)
    host.sshable.cmd("sudo adduser --disabled-password --gecos '' --home #{vm_home.shellescape} --uid #{uid} #{q_vm}")

    hop_prep
  end

  label def prep
    case host.sshable.cmd("common/bin/daemonizer --check prep_#{q_vm}")
    when "Succeeded"
      host.sshable.cmd("common/bin/daemonizer --clean prep_#{q_vm}")
      vm.nics.each { _1.incr_setup_nic }
      hop_run
    when "NotStarted", "Failed"
      secrets_json = JSON.generate({
        storage: storage_secrets
      })

      # Enable KVM access for VM user.
      host.sshable.cmd("sudo usermod -a -G kvm #{q_vm}")

      write_params_json

      host.sshable.cmd("common/bin/daemonizer 'sudo host/bin/setup-vm prep #{q_vm}' prep_#{q_vm}", stdin: secrets_json)
    end

    nap 1
  end

  def write_params_json
    topo = vm.cloud_hypervisor_cpu_topology

    # we don't write secrets to params_json, because it
    # shouldn't be stored in the host for security reasons.
    params_json = JSON.pretty_generate({
      "vm_name" => vm_name,
      "public_ipv6" => vm.ephemeral_net6.to_s,
      "public_ipv4" => vm.ip4.to_s || "",
      "local_ipv4" => local_ipv4,
      "unix_user" => vm.unix_user,
      "ssh_public_key" => vm.public_key,
      "nics" => vm.nics.map { |nic| [nic.private_ipv6.to_s, nic.private_ipv4.to_s, nic.ubid_to_tap_name, nic.mac] },
      "boot_image" => vm.boot_image,
      "max_vcpus" => topo.max_vcpus,
      "cpu_topology" => topo.to_s,
      "mem_gib" => vm.mem_gib,
      "ndp_needed" => host.ndp_needed,
      "storage_volumes" => storage_volumes,
      "swap_size_bytes" => frame["swap_size_bytes"],
      "pci_devices" => vm.pci_devices.map { [_1.slot, _1.iommu_group] }
    })

    host.sshable.cmd("sudo -u #{q_vm} tee #{params_path.shellescape}", stdin: params_json)
  end

  label def run
    host.sshable.cmd("sudo systemctl start #{q_vm}")
    hop_wait_sshable
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      # This is the first time we get into this state and we know that
      # wait_sshable will take definitely more than 15 seconds. So, we nap here
      # to reduce the amount of load on the control plane unnecessarily.
      nap 15
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
    Clog.emit("vm provisioned") { {vm: vm.values, provision: {vm_ubid: vm.ubid, vm_host_ubid: host.ubid, duration: Time.now - vm.allocated_at}} }
    project = vm.projects.first
    hop_wait unless project.billable

    BillingRecord.create_with_id(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmCores", vm.family, vm.location)["id"],
      amount: vm.cores
    )

    if vm.ip4_enabled
      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: vm.assigned_vm_address.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location)["id"],
        amount: 1
      )
    end

    hop_wait
  end

  label def wait
    when_start_after_host_reboot_set? do
      register_deadline(:wait, 5 * 60)
      hop_start_after_host_reboot
    end

    when_update_firewall_rules_set? do
      register_deadline(:wait, 5 * 60)
      hop_update_firewall_rules
    end

    when_update_spdk_dependency_set? do
      register_deadline(:wait, 5 * 60)
      hop_update_spdk_dependency
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
        Prog::PageNexus.assemble("#{vm} is unavailable", vm.ubid, "VmUnavailable", vm.ubid)
      end
    rescue Sshable::SshError
      # Host is likely to be down, which will be handled by HostNexus. No need
      # to create a page for this case.
    end

    nap 30
  end

  label def prevent_destroy
    register_deadline(:destroy, 24 * 60 * 60)
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
        host.sshable.cmd("sudo systemctl stop #{q_vm}")
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.stderr)
      end

      begin
        host.sshable.cmd("sudo systemctl stop #{q_vm}-dnsmasq")
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.stderr)
      end

      host.sshable.cmd("sudo host/bin/setup-vm delete #{q_vm}")
    end

    DB.transaction do
      vm.nics.map do |nic|
        nic.update(vm_id: nil)
        nic.incr_destroy
      end

      vm.vm_storage_volumes.each do |vol|
        vol.storage_device_dataset.update(available_storage_gib: Sequel[:available_storage_gib] + vol.size_gib)
      end

      VmHost.dataset.where(id: vm.vm_host_id).update(
        used_cores: Sequel[:used_cores] - vm.cores,
        used_hugepages_1g: Sequel[:used_hugepages_1g] - vm.mem_gib
      )

      vm.pci_devices_dataset.update(vm_id: nil)

      vm.projects.map { vm.dissociate_with_project(_1) }
      vm.destroy
    end

    pop "vm deleted"
  end

  label def start_after_host_reboot
    vm.update(display_state: "starting")

    secrets_json = JSON.generate({
      storage: storage_secrets
    })

    host.sshable.cmd("sudo host/bin/setup-vm recreate-unpersisted #{q_vm}", stdin: secrets_json)
    host.sshable.cmd("sudo systemctl start #{q_vm}")
    vm.nics.each { _1.incr_repopulate }

    vm.update(display_state: "running")

    decr_start_after_host_reboot

    vm.incr_update_firewall_rules
    hop_wait
  end

  def available?
    host.sshable.cmd("systemctl is-active #{vm.inhost_name} #{vm.inhost_name}-dnsmasq").split("\n").all?("active")
  end
end
