# frozen_string_literal: true

require "netaddr"
require "json"
require "ulid"
require "shellwords"

class Prog::Vm::Nexus < Prog::Base
  semaphore :destroy, :refresh_mesh

  def self.assemble(public_key, project_id, name: nil, size: "m5a.2x",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: "ubuntu-jammy",
    private_subnets: [], storage_size_gib: 20)

    project = Project[project_id]
    unless project || Config.development?
      fail "No existing project"
    end

    id = SecureRandom.uuid
    name ||= Vm.uuid_to_name(id)

    Validation.validate_name(name)

    # if the caller hasn't provided any subnets, generate a random one
    if private_subnets.empty?
      private_subnets.append([random_ula, random_private_ipv4])
    end

    DB.transaction do
      vm = Vm.create(public_key: public_key, unix_user: unix_user,
        name: name, size: size, location: location, boot_image: boot_image) { _1.id = id }
      vm.associate_with_project(project)
      private_subnets.each do |net6, net4|
        VmPrivateSubnet.create(vm_id: vm.id, private_subnet: net6.to_s, net4: net4.to_s)
      end
      VmStorageVolume.create(
        vm_id: vm.id,
        boot: true,
        size_gib: storage_size_gib,
        disk_index: 0
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

  def self.random_ula
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    NetAddr::IPv6Net.new(network_address, network_mask)
  end

  def self.random_private_ipv4
    addr = NetAddr::IPv4Net.parse("192.168.0.0/24")
    network_mask = NetAddr::Mask32.new(32)
    NetAddr::IPv4Net.new(addr.nth(SecureRandom.random_number(addr.len)), network_mask)
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

  def private_subnets
    @private_subnets ||= vm.private_subnets
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
        "device_id" => s.device_id
      }
    }
  end

  def allocation_dataset
    DB[<<SQL, vm.cores, vm.mem_gib_ratio, vm.mem_gib, vm.location]
SELECT *, vm_host.total_mem_gib / vm_host.total_cores AS mem_ratio
FROM vm_host
WHERE vm_host.used_cores + ? < vm_host.total_cores
AND vm_host.total_mem_gib / vm_host.total_cores >= ?
AND vm_host.used_hugepages_1g + ? < vm_host.total_hugepages_1g
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
        used_hugepages_1g: Sequel[:used_hugepages_1g] + vm.mem_gib
      )

    vm_host_id
  end

  def start
    vm_host_id = allocate
    vm_host = VmHost[vm_host_id]
    ip4, address = vm_host.ip4_random_vm_network
    vm.update(vm_host_id: vm_host_id, ephemeral_net6: vm_host.ip6_random_vm_network.to_s,
      local_vetho_ip: ip4 ? vm_host.veth_pair_random_ip4_addr.to_s : nil)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: ip4.to_s, address_id: address.id) if ip4
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

  def prep
    topo = vm.cloud_hypervisor_cpu_topology
    params_json = JSON.pretty_generate({
      "vm_name" => vm_name,
      "public_ipv6" => q_net6,
      "public_ipv4" => q_net4,
      "local_ipv4" => local_ipv4,
      "private_ipv4" => private_subnets.first&.last&.to_s&.shellescape || "",
      "unix_user" => unix_user,
      "ssh_public_key" => public_key,
      "private_subnets" => private_subnets.map { _1.map(&:to_s) },
      "boot_image" => vm.boot_image,
      "max_vcpus" => topo.max_vcpus,
      "cpu_topology" => topo.to_s,
      "mem_gib" => vm.mem_gib,
      "ndp_needed" => host.ndp_needed,
      "storage_volumes" => storage_volumes
    })

    # Enable KVM access for VM user.
    host.sshable.cmd("sudo usermod -a -G kvm #{q_vm}")

    # put prep.json
    params_path = File.join(vm_home, "prep.json")
    host.sshable.cmd("echo #{params_json.shellescape} | sudo -u #{q_vm} tee #{params_path.shellescape}")

    host.sshable.cmd("sudo bin/prepvm.rb #{params_path.shellescape}")
    hop :trigger_refresh_mesh
  end

  def trigger_refresh_mesh
    Vm.each do |vm|
      vm.incr_refresh_mesh
    end

    hop :run
  end

  def create_ipsec_tunnel(my_subnet6, my_subnet4, dst_vm, dst_subnet6, dst_subnet4)
    q_dst_name = dst_vm.inhost_name.shellescape
    q_dst_net = dst_vm.ephemeral_net6.to_s.shellescape

    my_params = "#{q_vm} #{q_net6} #{my_subnet6.to_s.shellescape} #{my_subnet4.to_s.shellescape}"
    dst_params = "#{q_dst_name} #{q_dst_net} #{dst_subnet6.to_s.shellescape} #{dst_subnet4.to_s.shellescape}"

    spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    spi4 = "0x" + SecureRandom.bytes(4).unpack1("H*")
    key = "0x" + SecureRandom.bytes(36).unpack1("H*")

    pp "sudo bin/setup-ipsec setup_src #{my_params} #{dst_params} #{spi} #{spi4} #{key}"
    host.sshable.cmd("sudo bin/setup-ipsec setup_src #{my_params} #{dst_params} #{spi} #{spi4} #{key}")
    pp "sudo bin/setup-ipsec setup_dst #{my_params} #{dst_params} #{spi} #{spi4} #{key}"
    dst_vm.vm_host.sshable.cmd("sudo bin/setup-ipsec setup_dst #{my_params} #{dst_params} #{spi} #{spi4} #{key}")
  end

  def create_private_route(my_subnet, dst_subnet)
    ipv6_privs = [my_subnet.first, dst_subnet.first]
    ipv4_privs = [my_subnet.last, dst_subnet.last]
    [ipv6_privs, ipv4_privs].each do |src_ip, dst_ip|
      begin
        pp "sudo ip -n #{q_vm} route add #{src_ip.to_s.shellescape} dev tap#{q_vm}"
        host.sshable.cmd("sudo ip -n #{q_vm} route add #{src_ip.to_s.shellescape} dev tap#{q_vm}")
      rescue Sshable::SshError => ex
        pp ex.message
      end

      begin
        pp "sudo ip -n #{q_vm} route add #{dst_ip.to_s.shellescape} dev vethi#{q_vm}"
        host.sshable.cmd("sudo ip -n #{q_vm} route add #{dst_ip.to_s.shellescape} dev vethi#{q_vm}")
      rescue Sshable::SshError => ex
        pp ex.message
      end
    end
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

    nap 30
  end

  def refresh_mesh
    # YYY: Implement a robust mesh networking concurrency algorithm.
    unless Config.development?
      decr_refresh_mesh
      hop :wait
    end

    # don't create tunnels to self or VMs already connected to
    reject_list = vm.ipsec_tunnels.map(&:src_vm_id)
    reject_list.append(vm.id)

    vms = Vm.reject { reject_list.include? _1.id }

    vms.each do |dst_vm|
      next if dst_vm.ephemeral_net6.nil?
      private_subnets.each do |my_subnet|
        dst_vm.private_subnets.each do |dst_subnet|
          create_ipsec_tunnel(my_subnet.first, my_subnet.last, dst_vm, dst_subnet.first, dst_subnet.last)
          create_private_route(my_subnet, dst_subnet)
        end
      end

      # record that we created the tunnel from this vm to dst_vm
      IpsecTunnel.create(src_vm_id: vm.id, dst_vm_id: dst_vm.id)
    end

    decr_refresh_mesh

    hop :wait
  end

  def destroy
    unless host.nil?
      begin
        host.sshable.cmd("sudo systemctl stop #{q_vm}")
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.message)
      end

      begin
        host.sshable.cmd("sudo systemctl stop #{q_vm}-dnsmasq")
      rescue Sshable::SshError => ex
        raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.message)
      end

      host.sshable.cmd("sudo bin/deletevm.rb #{q_vm}")
    end

    DB.transaction do
      vm.vm_private_subnet_dataset.delete
      VmHost.dataset.where(id: vm.vm_host_id).update(
        used_cores: Sequel[:used_cores] - vm.cores
      )
      vm.projects.map { vm.dissociate_with_project(_1) }
      # YYY: We should remove existing tunnels on dataplane too. Not hopping to
      # :refresh_mesh label directly, because it doesn't remove deleted ones, only
      # create missing ones.
      IpsecTunnel.where(src_vm_id: vm.id).or(dst_vm_id: vm.id).delete
      vm.delete
    end

    pop "vm deleted"
  end
end
