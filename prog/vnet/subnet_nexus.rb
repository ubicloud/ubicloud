# frozen_string_literal: true

class Prog::Vnet::SubnetNexus < Prog::Base
  subject_is :private_subnet
  semaphore :destroy, :refresh_keys, :add_new_nic, :update_firewall_rules

  def self.assemble(project_id, name: nil, location: "hetzner-hel1", ipv6_range: nil, ipv4_range: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    ubid = PrivateSubnet.generate_ubid
    name ||= PrivateSubnet.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_location(location, project.provider)

    ipv6_range ||= random_private_ipv6(location).to_s
    ipv4_range ||= random_private_ipv4(location).to_s
    DB.transaction do
      ps = PrivateSubnet.create(name: name, location: location, net6: ipv6_range, net4: ipv4_range, state: "waiting") { _1.id = ubid.to_uuid }
      ps.associate_with_project(project)
      FirewallRule.create_with_id(
        ip: "0.0.0.0/0",
        private_subnet_id: ps.id
      )
      FirewallRule.create_with_id(
        ip: "::/0",
        private_subnet_id: ps.id
      )
      Strand.create(prog: "Vnet::SubnetNexus", label: "wait") { _1.id = ubid.to_uuid }
    end
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_refresh_keys_set? do
      private_subnet.update(state: "refreshing_keys")
      hop_refresh_keys
    end

    when_add_new_nic_set? do
      private_subnet.update(state: "adding_new_nic")
      hop_add_new_nic
    end

    when_update_firewall_rules_set? do
      private_subnet.update(state: "updating_firewall_rules")
      hop_update_firewall_rules
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

  label def update_firewall_rules
    decr_update_firewall_rules
    private_subnet.vms.each do |vm|
      bud Prog::Vnet::UpdateFirewallRules, {subject_id: vm.id}, :update_firewall_rules
    end

    hop_wait_fw_rules
  end

  label def wait_fw_rules
    reap
    if leaf?
      private_subnet.update(state: "waiting")
      hop_wait
    end

    donate
  end

  label def add_new_nic
    nics_snap = nics_to_rekey
    nics_snap.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      create_tunnels(nics_snap, nic)
    end

    decr_add_new_nic
    hop_wait_inbound_setup
  end

  label def refresh_keys
    active_nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
    end

    decr_refresh_keys
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
      end

      hop_wait
    end

    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)

    if private_subnet.nics.any? { |n| !n.vm_id.nil? }
      Clog.emit "Cannot destroy subnet with active nics, first clean up the attached resources" do
        {private_subnet: private_subnet.values}
      end

      nap 5
    end

    decr_destroy

    if private_subnet.nics.empty?
      DB.transaction do
        private_subnet.firewall_rules.map(&:destroy)
        private_subnet.projects.each { |p| private_subnet.dissociate_with_project(p) }
        private_subnet.destroy
      end
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      nap 1
    end
  end

  def self.random_private_ipv6(location)
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    addr = NetAddr::IPv6Net.new(network_address, network_mask)
    return random_private_ipv6(location) unless PrivateSubnet.where(net6: addr.to_s, location: location).first.nil?

    addr
  end

  def self.random_private_ipv4(location)
    private_range = PrivateSubnet.random_subnet
    addr = NetAddr::IPv4Net.parse(private_range)

    selected_addr = addr.nth_subnet(26, SecureRandom.random_number(2**(26 - addr.netmask.prefix_len) - 1).to_i + 1)
    return random_private_ipv4(location) unless PrivateSubnet.where(net4: selected_addr.to_s, location: location).first.nil?

    selected_addr
  end

  def create_tunnels(nics, src_nic)
    nics.each do |dst_nic|
      next if src_nic == dst_nic
      IpsecTunnel.create_with_id(src_nic_id: src_nic.id, dst_nic_id: dst_nic.id) unless IpsecTunnel[src_nic_id: src_nic.id, dst_nic_id: dst_nic.id]
      IpsecTunnel.create_with_id(src_nic_id: dst_nic.id, dst_nic_id: src_nic.id) unless IpsecTunnel[src_nic_id: dst_nic.id, dst_nic_id: src_nic.id]
    end
  end

  def to_be_added_nics
    private_subnet.nics.select { _1.strand.label == "wait_setup" }
  end

  def active_nics
    private_subnet.nics.select { _1.strand.label == "wait" }
  end

  def nics_to_rekey
    active_nics + to_be_added_nics
  end

  def rekeying_nics
    private_subnet.nics.select { !_1.rekey_payload.nil? }
  end
end
