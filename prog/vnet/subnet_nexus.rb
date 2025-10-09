# frozen_string_literal: true

class Prog::Vnet::SubnetNexus < Prog::Base
  subject_is :private_subnet

  def self.assemble(project_id, name: nil, location_id: Location::HETZNER_FSN1_ID, ipv6_range: nil, ipv4_range: nil, allow_only_ssh: false, firewall_id: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end
    if allow_only_ssh && firewall_id
      fail "Cannot specify both allow_only_ssh and firewall_id"
    end

    ubid = PrivateSubnet.generate_ubid
    id = ubid.to_uuid
    name ||= PrivateSubnet.ubid_to_name(ubid)

    Validation.validate_name(name)

    ipv6_range ||= random_private_ipv6(location, project).to_s
    ipv4_range ||= random_private_ipv4(location, project, location.aws? ? PrivateSubnet::DEFAULT_AWS_SUBNET_PREFIX_LEN : PrivateSubnet::DEFAULT_SUBNET_PREFIX_LEN).to_s
    DB.transaction do
      ps = PrivateSubnet.create_with_id(id, name:, location_id: location.id, net6: ipv6_range, net4: ipv4_range, state: "waiting", project_id:)
      firewall_dataset = project.firewalls_dataset.where(location_id:)

      if firewall_id
        unless (firewall = firewall_dataset.first(Sequel[:firewall][:id] => firewall_id))
          fail "Firewall with id #{firewall_id} and location #{location.name} does not exist"
        end
      else
        port_range = allow_only_ssh ? 22..22 : 0..65535
        fw_name = "#{name[0, 55]}-default"
        # As is typical when checking before inserting, there is a race condition here with
        # a user concurrently manually creating a firewall with the same name.  However,
        # the worst case scenario is a bogus error message, and the user could try creating
        # the private subnet again.
        unless firewall_dataset.where(Sequel[:firewall][:name] => fw_name).empty?
          fw_name = "#{name[0, 47]}-default-#{Array.new(7) { UBID.from_base32(rand(32)) }.join}"
        end

        firewall = Firewall.create(name: fw_name, location_id: location.id, project_id:)
        DB.ignore_duplicate_queries do
          ["0.0.0.0/0", "::/0"].each { |cidr| FirewallRule.create(firewall_id: firewall.id, cidr: cidr, port_range: Sequel.pg_range(port_range)) }
        end
      end
      firewall.associate_with_private_subnet(ps, apply_firewalls: false)

      Strand.create_with_id(id, prog: "Vnet::SubnetNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        register_deadline(nil, 10 * 60)
        hop_destroy
      end
    end
  end

  label def start
    if private_subnet.location.aws?
      PrivateSubnetAwsResource.create_with_id(private_subnet.id) unless private_subnet.private_subnet_aws_resource
      bud Prog::Aws::Vpc, {"subject_id" => private_subnet.id}, :create_vpc
      hop_wait_vpc_created
    else
      hop_wait
    end
  end

  label def wait_vpc_created
    reap(:wait, nap: 2)
  end

  label def wait
    if private_subnet.location.aws?
      check_firewall_update
      private_subnet.semaphores.each(&:destroy)
      nap 60 * 60 * 24 * 365
    end

    when_refresh_keys_set? do
      private_subnet.update(state: "refreshing_keys")
      hop_refresh_keys
    end

    when_add_new_nic_set? do
      private_subnet.update(state: "adding_new_nic")
      hop_add_new_nic
    end

    check_firewall_update

    if private_subnet.last_rekey_at < Time.now - 60 * 60 * 24
      private_subnet.incr_refresh_keys
    end

    nap 10 * 60
  end

  def check_firewall_update
    when_update_firewall_rules_set? do
      private_subnet.vms.each(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end
  end

  def gen_encryption_key
    "0x" + SecureRandom.bytes(36).unpack1("H*")
  end

  def gen_spi
    "0x" + SecureRandom.bytes(4).unpack1("H*")
  end

  def gen_reqid
    SecureRandom.random_number(100000) + 1
  end

  label def add_new_nic
    register_deadline("wait", 3 * 60)
    nics_snap = nics_to_rekey
    nap 10 if nics_snap.any? { |nic| nic.lock_set? }
    nics_snap.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      nic.incr_lock
      private_subnet.create_tunnels(nics_snap, nic)
    end

    decr_add_new_nic
    hop_wait_inbound_setup
  end

  label def refresh_keys
    decr_refresh_keys
    nics = active_nics
    nap 10 if nics.any? { |nic| nic.lock_set? }
    nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      nic.incr_lock
    end

    hop_wait_inbound_setup
  end

  label def wait_inbound_setup
    nics = rekeying_nics
    if nics.all? { |nic| nic.strand.label == "wait_rekey_outbound_trigger" }
      nics.each(&:incr_trigger_outbound_update)
      hop_wait_outbound_setup
    end

    nap 5
  end

  label def wait_outbound_setup
    nics = rekeying_nics
    if nics.all? { |nic| nic.strand.label == "wait_rekey_old_state_drop_trigger" }
      nics.each(&:incr_old_state_drop_trigger)
      hop_wait_old_state_drop
    end

    nap 5
  end

  label def wait_old_state_drop
    nics = rekeying_nics
    if nics.all? { |nic| nic.strand.label == "wait" }
      private_subnet.update(state: "waiting", last_rekey_at: Time.now)
      nics.each do |nic|
        nic.update(encryption_key: nil, rekey_payload: nil)
        nic.unlock
      end
      hop_wait
    end

    nap 5
  end

  label def destroy
    if private_subnet.nics.any? { |n| !n.vm_id.nil? }
      register_deadline(nil, 10 * 60, allow_extension: true) if private_subnet.nics.any? { |n| n.vm&.prevent_destroy_set? }

      Clog.emit("Cannot destroy subnet with active nics, first clean up the attached resources") { private_subnet }

      nap 5
    end

    decr_destroy
    if private_subnet.location.aws?
      private_subnet.nics.map(&:incr_destroy)
      private_subnet.firewalls.map(&:destroy)
      Semaphore.incr(strand.children_dataset.where(prog: "Aws::Vpc").select(:id), "destroy")
      bud Prog::Aws::Vpc, {"subject_id" => private_subnet.id}, :destroy
      hop_wait_aws_vpc_destroyed
    end
    private_subnet.firewalls.map { it.disassociate_from_private_subnet(private_subnet, apply_firewalls: false) }

    private_subnet.connected_subnets.each do |subnet|
      private_subnet.disconnect_subnet(subnet)
    end

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      private_subnet.destroy
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap rand(5..10)
    end
  end

  label def wait_aws_vpc_destroyed
    reap(nap: 10) do
      nap 5 unless private_subnet.nics.empty?
      private_subnet.private_subnet_aws_resource.destroy
      private_subnet.destroy
      pop "vpc destroyed"
    end
  end

  def self.random_private_ipv6(location, project)
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    selected_addr = NetAddr::IPv6Net.new(network_address, network_mask)

    selected_addr = random_private_ipv6(location, project) if project.private_subnets_dataset[net6: selected_addr.to_s, location_id: location.id]

    selected_addr
  end

  def self.random_private_ipv4(location, project, cidr_size = 26)
    raise ArgumentError, "CIDR size must be between 0 and 32" unless cidr_size.between?(0, 32)

    private_range = PrivateSubnet.random_subnet
    addr = NetAddr::IPv4Net.parse(private_range)

    selected_addr = if addr.netmask.prefix_len < cidr_size
      addr.nth_subnet(cidr_size, SecureRandom.random_number(2**(cidr_size - addr.netmask.prefix_len) - 1).to_i + 1)
    else
      random_private_ipv4(location, project, cidr_size)
    end

    selected_addr = random_private_ipv4(location, project, cidr_size) if PrivateSubnet::BANNED_IPV4_SUBNETS.any? { it.rel(selected_addr) } || project.private_subnets_dataset[net4: selected_addr.to_s, location_id: location.id]

    selected_addr
  end

  def active_nics
    nics_with_strand_label("wait").all
  end

  def nics_to_rekey
    nics_with_strand_label(%w[wait wait_setup]).all
  end

  def rekeying_nics
    all_connected_nics.eager(:strand).exclude(rekey_payload: nil).all
  end

  private

  def all_connected_nics
    private_subnet.find_all_connected_nics
  end

  def nics_with_strand_label(label)
    all_connected_nics.join(:strand, {id: :id, label:}).select_all(:nic)
  end
end
