# frozen_string_literal: true

class Prog::Vnet::SubnetNexus < Prog::Base
  subject_is :private_subnet

  def self.assemble(project_id, name: nil, location: "hetzner-fsn1", ipv6_range: nil, ipv4_range: nil, allow_only_ssh: false, firewall_id: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end
    if allow_only_ssh && firewall_id
      fail "Cannot specify both allow_only_ssh and firewall_id"
    end

    ubid = PrivateSubnet.generate_ubid
    name ||= PrivateSubnet.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_location(location)

    ipv6_range ||= random_private_ipv6(location, project).to_s
    ipv4_range ||= random_private_ipv4(location, project).to_s
    DB.transaction do
      ps = PrivateSubnet.create(name: name, location: location, net6: ipv6_range, net4: ipv4_range, state: "waiting", project_id:) { _1.id = ubid.to_uuid }
      ps.associate_with_project(project)

      firewall = if firewall_id
        existing_fw = project.firewalls_dataset.where(location: location).first(Sequel[:firewall][:id] => firewall_id)
        fail "Firewall with id #{firewall_id} and location #{location} does not exist" unless existing_fw
        existing_fw
      else
        port_range = allow_only_ssh ? 22..22 : 0..65535
        new_fw = Firewall.create_with_id(name: "#{name}-default", location: location, project_id:)
        new_fw.associate_with_project(project)
        ["0.0.0.0/0", "::/0"].each { |cidr| FirewallRule.create_with_id(firewall_id: new_fw.id, cidr: cidr, port_range: Sequel.pg_range(port_range)) }
        new_fw
      end
      firewall.associate_with_private_subnet(ps, apply_firewalls: false)

      Strand.create(prog: "Vnet::SubnetNexus", label: "wait") { _1.id = ubid.to_uuid }
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

  label def wait
    when_refresh_keys_set? do
      private_subnet.update(state: "refreshing_keys")
      hop_refresh_keys
    end

    when_add_new_nic_set? do
      private_subnet.update(state: "adding_new_nic")
      hop_add_new_nic
    end

    when_update_firewall_rules_set? do
      private_subnet.vms.map(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end

    if private_subnet.last_rekey_at < Time.now - 60 * 60 * 24
      private_subnet.incr_refresh_keys
    end

    nap 30
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
    nap 10 if active_nics.any? { |nic| nic.lock_set? }
    active_nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      nic.incr_lock
    end

    hop_wait_inbound_setup
  end

  label def wait_inbound_setup
    if rekeying_nics.all? { |nic| nic.strand.label == "wait_rekey_outbound_trigger" }
      rekeying_nics.each(&:incr_trigger_outbound_update)
      hop_wait_outbound_setup
    end

    nap 5
  end

  label def wait_outbound_setup
    if rekeying_nics.all? { |nic| nic.strand.label == "wait_rekey_old_state_drop_trigger" }
      rekeying_nics.each(&:incr_old_state_drop_trigger)
      hop_wait_old_state_drop
    end

    nap 5
  end

  label def wait_old_state_drop
    if rekeying_nics.all? { |nic| nic.strand.label == "wait" }
      private_subnet.update(state: "waiting", last_rekey_at: Time.now)
      rekeying_nics.each do |nic|
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
    strand.children.each { _1.destroy }
    private_subnet.firewalls.map { _1.disassociate_from_private_subnet(private_subnet, apply_firewalls: false) }

    private_subnet.connected_subnets.each do |subnet|
      private_subnet.disconnect_subnet(subnet)
    end

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      private_subnet.destroy
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap 1
    end
  end

  def self.random_private_ipv6(location, project)
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    selected_addr = NetAddr::IPv6Net.new(network_address, network_mask)

    selected_addr = random_private_ipv6(location, project) if project.private_subnets_dataset[Sequel[:net6] => selected_addr.to_s, :location => location]

    selected_addr
  end

  def self.random_private_ipv4(location, project)
    private_range = PrivateSubnet.random_subnet
    addr = NetAddr::IPv4Net.parse(private_range)

    selected_addr = addr.nth_subnet(26, SecureRandom.random_number(2**(26 - addr.netmask.prefix_len) - 1).to_i + 1)

    selected_addr = random_private_ipv4(location, project) if PrivateSubnet::BANNED_IPV4_SUBNETS.any? { _1.rel(selected_addr) } || project.private_subnets_dataset[Sequel[:net4] => selected_addr.to_s, :location => location]

    selected_addr
  end

  def to_be_added_nics
    private_subnet.find_all_connected_nics.select { _1.strand.label == "wait_setup" }
  end

  def active_nics
    private_subnet.find_all_connected_nics.select { _1.strand.label == "wait" }
  end

  def nics_to_rekey
    (active_nics + to_be_added_nics).uniq
  end

  def rekeying_nics
    private_subnet.find_all_connected_nics.select { !_1.rekey_payload.nil? }
  end
end
