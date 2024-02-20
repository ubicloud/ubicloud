# frozen_string_literal: true

require_relative "../model"
require_relative "../lib/hosting/apis"

class VmHost < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id
  one_to_many :vms
  one_to_many :assigned_subnets, key: :routed_to_host_id, class: :Address
  one_to_one :hetzner_host, key: :id
  one_to_many :assigned_host_addresses, key: :host_id, class: :AssignedHostAddress
  one_to_many :spdk_installations, key: :vm_host_id
  one_to_many :storage_devices, key: :vm_host_id

  plugin :association_dependencies, assigned_host_addresses: :destroy, assigned_subnets: :destroy, hetzner_host: :destroy, spdk_installations: :destroy, storage_devices: :destroy

  include ResourceMethods
  include SemaphoreMethods
  semaphore :reboot, :destroy

  def host_prefix
    net6.netmask.prefix_len
  end

  def vm_addresses
    vms.filter_map(&:assigned_vm_address)
  end

  def provider
    hetzner_host ? HetznerHost::PROVIDER_NAME : nil
  end

  # Compute the IPv6 Subnet that can be used to address the host
  # itself, and should not be delegated to any VMs.
  #
  # The default prefix length is 79, so that customers can be given a
  # /80 for their own exclusive use, and paired is the adjacent /80
  # for Clover's use on behalf of that VM.  This leaves 15 bits of
  # entropy relative to the customary /64 allocated to a real device.
  #
  # Offering a /80 to the VM renders nicely in the IPv6 format, as
  # it's 5 * 16, and each delimited part of IPv6 is 16 bits.
  #
  # A /80 is the longest prefix that is divisible by 16 and contains
  # multiple /96 subnets within it.  /96 is of special significance
  # because it contains enough space within it to hold the IPv4
  # address space, i.e. leaving the door open for schemes relying on
  # SIIT translation: https://datatracker.ietf.org/doc/html/rfc7915
  def ip6_reserved_network(prefix = 79)
    # Interpret a nil ip6 address and a not-nil network as there being
    # no network reserved for the host in net6.
    #
    # The reason: some vendors prefer to delegate a network that
    # bypasses neighbor discovery protocol (NDP) that is different
    # than the network customarily assigned to the physical network
    # interface.
    #
    # And on at least one, the network interface *must* respond to
    # neighbor discovery for that customary network/IP in order to be
    # routed the delegated /64.  The two networks have no overlap with
    # one another.  So alas, our ability to auto-configure from the
    # host in such a case is limited.
    return nil if ip6.nil? && !net6.nil?
    fail "BUG: host prefix must be is shorter than reserved prefix" unless host_prefix < prefix

    NetAddr::IPv6Net.new(ip6, NetAddr::Mask128.new(prefix))
  end

  # Generate a random network that is a slice of the host's network
  # for delegation to a VM.
  def ip6_random_vm_network(prefix = 79)
    subnet_bits = prefix - host_prefix

    # Perform integer division, rounding up the number of random bytes
    # needed.
    bytes_needed = ((subnet_bits - 1) / 8) + 1

    # Generate bits to sit between the host_prefix and the vm network.
    #
    # Shift them into the right place for a 128 bit IPv6 address
    lower_bits = SecureRandom.bytes(bytes_needed).unpack1("n") << (128 - prefix - 1)

    # Combine it with the higher bits for the host.
    proposal = NetAddr::IPv6Net.new(
      NetAddr::IPv6.new(net6.network.addr | lower_bits), NetAddr::Mask128.new(prefix)
    )

    # :nocov:
    fail "BUG: host should be supernet of randomized subnet" unless net6.rel(proposal) == 1
    # :nocov:

    case (rn = ip6_reserved_network) && proposal.network.cmp(rn.network)
    when 0
      # Guard against choosing the host-reserved network for a guest
      # and try again.  Recursion is used here because it's a likely
      # code path, and if there's a bug, it's better to stack overflow
      # rather than loop forever.
      ip6_random_vm_network(prefix)
    else
      proposal
    end
  end

  def ip4_random_vm_network
    # we get the available subnets and if the subnet is /32, we eliminate it
    available_subnets = assigned_subnets.select { |a| a.cidr.version == 4 && a.cidr.network.to_s != sshable.host }
    # we eliminate the subnets that are full
    used_subnet = available_subnets.select { |as| as.assigned_vm_address.count != 2**(32 - as.cidr.netmask.prefix_len) }.sample

    # not available subnet
    return [nil, nil] unless used_subnet

    # we pick a random /31 subnet from the available subnet
    rand = SecureRandom.random_number(2**(32 - used_subnet.cidr.netmask.prefix_len)).to_i
    picked_subnet = used_subnet.cidr.nth(rand)
    # we check if the picked subnet is used by one of the vms
    return ip4_random_vm_network if vm_addresses.map { _1.ip.to_s }.include?("#{picked_subnet}/32")
    [picked_subnet, used_subnet]
  end

  def veth_pair_random_ip4_addr
    addr = NetAddr::IPv4Net.parse("169.254.0.0/16")
    # we get 1 address here and use the next address to assign
    # route for vetho* and vethi* devices. So, we are splitting the local address
    # space to two but only store 1 of them for the existence check.
    # that's why the range is 2 * ((addr.len - 2) / 2)
    selected_addr = NetAddr::IPv4Net.new(addr.nth(2 * SecureRandom.random_number((addr.len - 2) / 2)), NetAddr::Mask32.new(32))

    return veth_pair_random_ip4_addr if selected_addr.network.to_s.nil? || vms.any? { |vm| vm.local_vetho_ip == selected_addr.network.to_s }
    selected_addr
  end

  def sshable_address
    assigned_host_addresses.find { |a| a.ip.version == 4 }
  end

  def create_addresses(ip_records: nil)
    ip_records ||= Hosting::Apis.pull_ips(self)
    return if ip_records.nil? || ip_records.empty?

    DB.transaction do
      ip_records.each do |ip_record|
        ip_addr = ip_record.ip_address
        source_host_ip = ip_record.source_host_ip
        is_failover_ip = ip_record.is_failover

        next if assigned_subnets.any? { |a| a.cidr.to_s == ip_addr }

        # we need to find if it was previously created
        # if it was, we need to update the routed_to_host_id but only if there is no VM that's using it
        # if it wasn't, we need to create it
        adr = Address.where(cidr: ip_addr).first
        if adr && is_failover_ip
          if adr.assigned_vm_address.count > 0
            fail "BUG: failover ip #{ip_addr} is already assigned to a vm"
          end

          adr.update(routed_to_host_id: id)
        else
          if Sshable.where(host: source_host_ip).count == 0
            fail "BUG: source host #{source_host_ip} isn't added to the database"
          end
          adr = Address.create_with_id(cidr: ip_addr, routed_to_host_id: id, is_failover_ip: is_failover_ip)
        end

        unless is_failover_ip
          AssignedHostAddress.create_with_id(host_id: id, ip: ip_addr, address_id: adr.id)
        end
      end
    end

    Strand.create_with_id(schedule: Time.now, prog: "SetupNftables", label: "start", stack: [{subject_id: id}])
  end

  # Operational Functions

  # Introduced for refreshing rhizome programs via REPL.
  def install_rhizome(install_specs: false)
    Strand.create_with_id(schedule: Time.now, prog: "InstallRhizome", label: "start", stack: [{subject_id: id, target_folder: "host", install_specs: install_specs}])
  end

  # Introduced for downloading a new boot image via REPL.
  # Use with caution as the vm_host will not accept a new vm during the image download.
  def download_boot_image(image_name, custom_url = nil)
    Strand.create_with_id(schedule: Time.now, prog: "DownloadBootImage", label: "start", stack: [{subject_id: id, image_name: image_name, custom_url: custom_url}])
  end

  def hetznerify(server_id)
    DB.transaction do
      HetznerHost.create(server_identifier: server_id) { _1.id = id }
      create_addresses
    end
  end

  def set_data_center
    update(data_center: Hosting::Apis.pull_data_center(self))
  end

  def reset
    unless Config.development?
      fail "BUG: reset is only allowed in development"
    end

    Hosting::Apis.reset_server(self)
  end
end
