# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::Vm::Nexus < Prog::Base
  semaphore :destroy, :refresh_mesh, :start_after_host_reboot

  def self.assemble(public_key, project_id, name: nil, size: "m5a.2x",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: "ubuntu-jammy",
    private_subnet_id: nil, nic_id: nil, storage_size_gib: 20, storage_encrypted: false,
    enable_ip4: false)

    project = Project[project_id]
    unless project || Config.development?
      fail "No existing project"
    end
    Validation.validate_location(location, project&.provider)

    ubid = Vm.generate_ubid
    name ||= Vm.ubid_to_name(ubid)

    Validation.validate_name(name)

    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    key_wrapping_key = cipher.random_key
    key_wrapping_iv = cipher.random_iv

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
        subnet.add_nic(nic)
      end

      unless nic
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
        name: name, size: size, location: location, boot_image: boot_image, ip4_enabled: enable_ip4) { _1.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      vm.associate_with_project(project)

      if storage_encrypted
        key_encryption_key = StorageKeyEncryptionKey.create_with_id(
          algorithm: key_wrapping_algorithm,
          key: Base64.encode64(key_wrapping_key),
          init_vector: Base64.encode64(key_wrapping_iv),
          auth_data: "#{vm.inhost_name}_0"
        )
      end

      VmStorageVolume.create_with_id(
        vm_id: vm.id,
        boot: true,
        size_gib: storage_size_gib,
        disk_index: 0,
        key_encryption_key_1_id: storage_encrypted ? key_encryption_key.id : nil
      )

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

  def vm
    @vm ||= Vm[strand.id]
  end

  def host
    @host ||= vm.vm_host
  end

  def unix_user
    @unix_user ||= vm.unix_user
  end

  def public_key
    @public_key ||= vm.public_key
  end

  def q_net6
    vm.ephemeral_net6.to_s.shellescape
  end

  def q_net4
    vm.ip4.to_s || ""
  end

  def local_ipv4
    vm.local_vetho_ip&.to_s&.shellescape || ""
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
WHERE vm_host.used_cores + ? < vm_host.total_cores
AND vm_host.total_mem_gib / vm_host.total_cores >= ?
AND vm_host.used_hugepages_1g + ? < vm_host.total_hugepages_1g
AND vm_host.available_storage_gib > ?
AND vm_host.allocation_state = 'accepting'
AND vm_host.location = ?
ORDER BY mem_ratio, used_cores
SQL
  end

  def allocate
    vm_host_id = allocation_dataset.limit(1).get(:id)
    fail "no space left on any eligible hosts" unless vm_host_id

    # N.B. check constraint required to address concurrency.  By
    # injecting a crash from overbooking, it gives us the opportunity
    # to try again.
    VmHost.dataset
      .where(id: vm_host_id)
      .update(
        used_cores: Sequel[:used_cores] + vm.cores,
        used_hugepages_1g: Sequel[:used_hugepages_1g] + vm.mem_gib,
        available_storage_gib: Sequel[:available_storage_gib] - vm.storage_size_gib
      )

    vm_host_id
  end

  def start
    register_deadline(:wait, 10 * 60)

    vm_host_id = allocate
    vm_host = VmHost[vm_host_id]
    ip4, address = vm_host.ip4_random_vm_network if vm.ip4_enabled

    fail "no ip4 addresses left" if vm.ip4_enabled && !ip4

    vm.update(vm_host_id: vm_host_id, ephemeral_net6: vm_host.ip6_random_vm_network.to_s,
      local_vetho_ip: vm_host.veth_pair_random_ip4_addr.to_s)
    AssignedVmAddress.create_with_id(dst_vm_id: vm.id, ip: ip4.to_s, address_id: address.id) if ip4
    hop :create_unix_user
  end

  def create_unix_user
    # create vm's user and home directory
    begin
      host.sshable.cmd("sudo adduser --disabled-password --gecos '' --home #{vm_home.shellescape} #{q_vm}")
    rescue Sshable::SshError => ex
      raise unless /adduser: The user `.*' already exists\./.match?(ex.stderr)
    end

    hop :prep
  end

  def params_path
    @params_path ||= File.join(vm_home, "prep.json")
  end

  def prep
    topo = vm.cloud_hypervisor_cpu_topology

    # we don't write secrets to params_json, because it
    # shouldn't be stored in the host for security reasons.
    params_json = JSON.pretty_generate({
      "vm_name" => vm_name,
      "public_ipv6" => q_net6,
      "public_ipv4" => q_net4,
      "local_ipv4" => local_ipv4,
      "unix_user" => unix_user,
      "ssh_public_key" => public_key,
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

    host.sshable.cmd("sudo bin/prepvm.rb #{params_path.shellescape}", stdin: secrets_json)
    hop :trigger_refresh_mesh
  end

  def trigger_refresh_mesh
    vm.private_subnets.each { |ps| ps.incr_refresh_mesh }

    hop :run
  end

  def run
    host.sshable.cmd("sudo systemctl start #{q_vm}")
    vm.update(display_state: "running")
    hop :wait
  end

  def wait
    when_destroy_set? do
      hop :destroy
    end

    when_refresh_mesh_set? do
      hop :refresh_mesh
    end

    when_start_after_host_reboot_set? do
      hop :start_after_host_reboot
    end

    nap 30
  end

  def refresh_mesh
    register_deadline(:wait, 5 * 60)

    # YYY: Implement a robust mesh networking concurrency algorithm.
    unless Config.development?
      decr_refresh_mesh
      hop :wait
    end

    vm.private_subnets.each { |ps| ps.incr_refresh_mesh }
    decr_refresh_mesh
    hop :wait
  end

  def destroy
    register_deadline(nil, 5 * 60)

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

      host.sshable.cmd("sudo bin/deletevm.rb #{q_vm}")
    end

    DB.transaction do
      vm.nics.map do |nic|
        nic.update(vm_id: nil)
        nic.incr_destroy
      end

      vm.assigned_vm_address_dataset.destroy
      vm.vm_storage_volumes_dataset.destroy

      VmHost.dataset.where(id: vm.vm_host_id).update(
        used_cores: Sequel[:used_cores] - vm.cores
      )
      vm.projects.map { vm.dissociate_with_project(_1) }

      vm.destroy
    end

    pop "vm deleted"
  end

  def start_after_host_reboot
    register_deadline(:wait, 5 * 60)

    secrets_json = JSON.generate({
      storage: storage_secrets
    })

    host.sshable.cmd("sudo bin/recreate-unpersisted #{params_path.shellescape}", stdin: secrets_json)
    host.sshable.cmd("sudo systemctl start #{q_vm}")

    decr_start_after_host_reboot

    # trigger setting up private subnet connections
    incr_refresh_mesh

    hop :wait
  end
end
