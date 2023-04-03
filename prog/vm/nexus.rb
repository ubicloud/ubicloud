# frozen_string_literal: true

require "netaddr"
require "json"
require "ulid"

class Prog::Vm::Nexus < Prog::Base
  semaphore :destroy, :refresh_mesh

  def self.assemble(public_key, name: nil, size: "standard-4",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: "ubuntu-jammy",
    private_subnets: [])

    # if the caller hasn't provided any subnets, generate a random one
    if private_subnets.empty?
      private_subnets.append(random_ula)
    end

    DB.transaction do
      id = SecureRandom.uuid
      name ||= uuid_to_name(id)
      vm = Vm.create(public_key: public_key, unix_user: unix_user,
        name: name, size: size, location: location, boot_image: boot_image) { _1.id = id }
      private_subnets.each do
        VmPrivateSubnet.create(vm_id: vm.id, private_subnet: _1.to_s)
      end

      Strand.create(prog: "Vm::Nexus", label: "start") { _1.id = vm.id }
    end
  end

  def self.uuid_to_name(id)
    "vm" + ULID.from_uuidish(id).to_s[0..5].downcase
  end

  def vm_name
    # YYY: various names in linux, like interface names, are obliged
    # to be short, so alas, probably can't reproduce entropy from
    # vm.id to be collision free and there will need to be a second
    # addressing scheme scoped to each VmHost.  But for now, assume
    # entropy.
    self.class.uuid_to_name(vm.id)
  end

  def q_vm
    vm_name.shellescape
  end

  def self.random_ula
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    NetAddr::IPv6Net.new(network_address, network_mask)
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

  def q_net
    vm.ephemeral_net6.to_s.shellescape
  end

  def start
    # Prototype quality vm allocator: find least-used host to
    # demonstrate features that span hosts, because it ends up being
    # like round-robin in a non-concurrent allocation-only
    # demonstration.
    #
    # YYY: Lacks many necessary features like supporting different VM
    # sizes and preventing over-allocation.  The allocator should also
    # run in the strand of the host or do some other interlock to
    # avoid overbooking in concurrent scenarios, but that requires
    # more inter-strand synchronization than I want to do right now.
    vm_host_id = DB[<<SQL, vm.location].first[:id]
SELECT id
FROM (SELECT vm_host.id, count(*)
      FROM vm_host LEFT JOIN vm ON
      vm_host.id = vm.vm_host_id
      AND vm_host.allocation_state = 'accepting'
      AND vm_host.location = ?
      GROUP BY vm_host.id) AS counts
ORDER BY count
LIMIT 1
SQL

    vm.update(vm_host_id: vm_host_id, ephemeral_net6: VmHost[vm_host_id].ip6_random_vm_network.to_s)
    hop :prep
  end

  def prep
    params_json = JSON.pretty_generate({
      "vm_name" => vm_name,
      "public_ipv6" => q_net,
      "unix_user" => unix_user,
      "ssh_public_key" => public_key,
      "private_subnets" => private_subnets.map { _1.to_s },
      "boot_image" => vm.boot_image
    })

    # create vm's home directory
    vm_home = File.join("", "vm", vm_name)
    host.sshable.cmd("sudo adduser --disabled-password --gecos '' --home #{vm_home.shellescape} #{q_vm}")
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

  def create_ipsec_tunnel(my_subnet, dst_vm, dst_subnet)
    q_dst_name = self.class.uuid_to_name(dst_vm.id).shellescape
    q_dst_net = dst_vm.ephemeral_net6.to_s.shellescape

    my_params = "#{q_vm} #{q_net} #{my_subnet.to_s.shellescape}"
    dst_params = "#{q_dst_name} #{q_dst_net} #{dst_subnet.to_s.shellescape}"

    spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    key = "0x" + SecureRandom.bytes(36).unpack1("H*")

    host.sshable.cmd("sudo bin/setup-ipsec setup_src #{my_params} #{dst_params} #{spi} #{key}")
    dst_vm.vm_host.sshable.cmd("sudo bin/setup-ipsec setup_dst #{my_params} #{dst_params} #{spi} #{key}")
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
    # don't create tunnels to self or VMs already connected to
    reject_list = vm.ipsec_tunnels.map(&:src_vm_id)
    reject_list.append(vm.id)

    vms = Vm.reject { reject_list.include? _1.id }

    vms.each do |dst_vm|
      private_subnets.each do |my_subnet|
        dst_vm.private_subnets.each do |dst_subnet|
          create_ipsec_tunnel(my_subnet, dst_vm, dst_subnet)
        end
      end

      # record that we created the tunnel from this vm to dst_vm
      IpsecTunnel.create(src_vm_id: vm.id, dst_vm_id: dst_vm.id)
    end

    decr_refresh_mesh

    hop :wait
  end

  def destroy
    # YYY make idempotent
    vm.vm_private_subnet_dataset.delete
    vm.delete
    host.sshable.cmd("sudo systemctl stop #{q_vm}")
    host.sshable.cmd("sudo bin/deletevm.rb #{q_vm}")
    pop "vm deleted"
  end
end
