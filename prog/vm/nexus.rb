# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::Vm::Nexus < Prog::Base
  subject_is :vm
  semaphore :destroy, :start_after_host_reboot

  def self.assemble(public_key, project_id, name: nil, size: "standard-2",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: "ubuntu-jammy",
    private_subnet_id: nil, nic_id: nil, storage_volumes: nil, boot_disk_index: 0,
    enable_ip4: false, pool_id: nil)

    unless (project = Project[project_id])
      fail "No existing project"
    end
    Validation.validate_location(location, project.provider)
    vm_size = Validation.validate_vm_size(size)

    storage_volumes ||= [{
      size_gib: vm_size.storage_size_gib,
      encrypted: true
    }]

    # allow missing fields to make testing during development more convenient.
    storage_volumes.each do |volume|
      volume[:size_gib] ||= vm_size.storage_size_gib
      volume[:encrypted] = true if !volume.has_key? :encrypted
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
          subnet_s = Prog::Vnet::SubnetNexus.assemble(project_id, name: "#{name}-subnet", location: location)
          subnet = PrivateSubnet[subnet_s.id]
        end
        nic_s = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{name}-nic")
        nic = Nic[nic_s.id]
      end

      vm = Vm.create(public_key: public_key, unix_user: unix_user,
        name: name, family: vm_size.family, cores: vm_size.vcpu / 2, location: location,
        boot_image: boot_image, ip4_enabled: enable_ip4, pool_id: pool_id) { _1.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      vm.associate_with_project(project)

      storage_volumes.each_with_index do |volume, disk_index|
        key_encryption_key = if volume[:encrypted]
          key_wrapping_algorithm = "aes-256-gcm"
          cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
          key_wrapping_key = cipher.random_key
          key_wrapping_iv = cipher.random_iv

          StorageKeyEncryptionKey.create_with_id(
            algorithm: key_wrapping_algorithm,
            key: Base64.encode64(key_wrapping_key),
            init_vector: Base64.encode64(key_wrapping_iv),
            auth_data: "#{vm.inhost_name}_#{disk_index}"
          )
        end

        VmStorageVolume.create_with_id(
          vm_id: vm.id,
          boot: disk_index == boot_disk_index,
          size_gib: volume[:size_gib],
          disk_index: disk_index,
          key_encryption_key_1_id: key_encryption_key&.id
        )
      end

      Strand.create(prog: "Vm::Nexus", label: "start") { _1.id = vm.id }
    end
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
        "size_gib" => s.size_gib,
        "device_id" => s.device_id,
        "disk_index" => s.disk_index,
        "encrypted" => !s.key_encryption_key_1.nil?
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

  def allocation_dataset
    DB[<<SQL, vm.cores, vm.mem_gib_ratio, vm.mem_gib, vm.storage_size_gib, vm.location]
SELECT *, vm_host.total_mem_gib / vm_host.total_cores AS mem_ratio
FROM vm_host
WHERE vm_host.used_cores + ? < least(vm_host.total_cores, vm_host.total_mem_gib / ?)
AND vm_host.used_hugepages_1g + ? < vm_host.total_hugepages_1g
AND vm_host.available_storage_gib > ?
AND vm_host.allocation_state = 'accepting'
AND vm_host.location = ?
ORDER BY mem_ratio, used_cores
SQL
  end

  def allocate
    vm_host_id = allocation_dataset.limit(1).get(:id)
    fail "#{vm} no space left on any eligible hosts for #{vm.location}" unless vm_host_id

    fail "concurrent allocation_state modification requires re-allocation" if VmHost.dataset
      .where(id: vm_host_id, allocation_state: "accepting")
      .update(
        used_cores: Sequel[:used_cores] + vm.cores,
        used_hugepages_1g: Sequel[:used_hugepages_1g] + vm.mem_gib,
        available_storage_gib: Sequel[:available_storage_gib] - vm.storage_size_gib
      ).zero?

    vm_host_id
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        vm.active_billing_record&.finalize
        vm.assigned_vm_address&.active_billing_record&.finalize
        hop_destroy
      end
    end
  end

  label def start
    register_deadline(:wait, 10 * 60)

    vm_host_id = allocate
    vm_host = VmHost[vm_host_id]
    ip4, address = vm_host.ip4_random_vm_network if vm.ip4_enabled

    fail "no ip4 addresses left" if vm.ip4_enabled && !ip4

    DB.transaction do
      vm.update(
        vm_host_id: vm_host_id,
        ephemeral_net6: vm_host.ip6_random_vm_network.to_s,
        local_vetho_ip: vm_host.veth_pair_random_ip4_addr.to_s
      )

      AssignedVmAddress.create_with_id(dst_vm_id: vm.id, ip: ip4.to_s, address_id: address.id) if ip4
    end
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
      "storage_volumes" => storage_volumes
    })

    secrets_json = JSON.generate({
      storage: storage_secrets
    })

    # Enable KVM access for VM user.
    host.sshable.cmd("sudo usermod -a -G kvm #{q_vm}")

    # put prep.json
    host.sshable.cmd("echo #{params_json.shellescape} | sudo -u #{q_vm} tee #{params_path.shellescape}")

    host.sshable.cmd("sudo host/bin/prepvm.rb #{params_path.shellescape}", stdin: secrets_json)
    hop_run
  end

  label def run
    vm.nics.each { _1.incr_setup_nic }
    host.sshable.cmd("sudo systemctl start #{q_vm}")
    BillingRecord.create_with_id(
      project_id: vm.projects.first.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmCores", vm.family, vm.location)["id"],
      amount: vm.cores
    )

    if vm.ip4_enabled
      BillingRecord.create_with_id(
        project_id: vm.projects.first.id,
        resource_id: vm.assigned_vm_address.id,
        resource_name: vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", vm.location)["id"],
        amount: 1
      )
    end

    hop_wait_sshable
  end

  label def wait_sshable
    addr = vm.ephemeral_net4 || vm.ephemeral_net6.nth(2)
    out = `ssh -o BatchMode=yes -o ConnectTimeout=1 -o PreferredAuthentications=none user@#{addr} 2>&1`
    if out.include? "Host key verification failed."
      vm.update(display_state: "running")
      hop_wait
    end
    nap 1
  end

  label def wait
    when_start_after_host_reboot_set? do
      hop_start_after_host_reboot
    end

    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)

    decr_destroy

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

      host.sshable.cmd("sudo host/bin/deletevm.rb #{q_vm}")
    end

    DB.transaction do
      vm.nics.map do |nic|
        nic.update(vm_id: nil)
        nic.incr_destroy
      end

      vm.assigned_vm_address_dataset.destroy

      VmHost.dataset.where(id: vm.vm_host_id).update(
        used_cores: Sequel[:used_cores] - vm.cores,
        used_hugepages_1g: Sequel[:used_hugepages_1g] - vm.mem_gib,
        available_storage_gib: Sequel[:available_storage_gib] + vm.storage_size_gib
      )
      vm.vm_storage_volumes_dataset.destroy
      vm.projects.map { vm.dissociate_with_project(_1) }
      vm.destroy
    end

    pop "vm deleted"
  end

  label def start_after_host_reboot
    register_deadline(:wait, 5 * 60)

    vm.update(display_state: "starting")

    secrets_json = JSON.generate({
      storage: storage_secrets
    })

    host.sshable.cmd("sudo host/bin/recreate-unpersisted #{params_path.shellescape}", stdin: secrets_json)
    host.sshable.cmd("sudo systemctl start #{q_vm}")

    vm.update(display_state: "running")

    decr_start_after_host_reboot

    hop_wait
  end
end
