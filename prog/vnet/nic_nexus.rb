# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  subject_is :nic
  semaphore :destroy, :detach_vm, :start_rekey, :trigger_outbound_update, :old_state_drop_trigger, :setup_nic, :repopulate

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil)
    unless (subnet = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = Nic.generate_ubid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s
    ipv4_addr ||= subnet.random_private_ipv4.to_s

    DB.transaction do
      Nic.create(private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac: gen_mac, name: name, private_subnet_id: private_subnet_id) { _1.id = ubid.to_uuid }
      Strand.create(prog: "Vnet::NicNexus", label: "wait_vm") { _1.id = ubid.to_uuid }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def wait_vm
    nap 60 unless nic.vm
    when_setup_nic_set? do
      hop_add_subnet_addr
    end
    nap 1
  end

  label def add_subnet_addr
    bud Prog::Vnet::RekeyNicTunnel, {}, :add_subnet_addr
    hop_wait_add_subnet_addr
  end

  label def wait_add_subnet_addr
    reap
    if leaf?
      nic.private_subnet.incr_add_new_nic
      hop_wait_setup
    end
    donate
  end

  label def wait_setup
    when_start_rekey_set? do
      decr_setup_nic
      hop_start_rekey
    end
    nap 5
  end

  label def wait
    when_detach_vm_set? do
      hop_detach_vm
    end

    when_repopulate_set? do
      hop_repopulate
    end

    when_start_rekey_set? do
      hop_start_rekey
    end

    nap 30
  end

  label def repopulate
    bud Prog::Vnet::RekeyNicTunnel, {}, :add_subnet_addr
    hop_wait_repopulate
  end

  label def wait_repopulate
    reap
    if leaf?
      decr_repopulate
      nic.private_subnet.incr_refresh_keys
      hop_wait
    end

    donate
  end

  label def start_rekey
    bud Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound
    hop_wait_rekey_inbound
  end

  label def wait_rekey_inbound
    reap
    if leaf?
      decr_start_rekey
      hop_wait_rekey_outbound_trigger
    end

    donate
  end

  label def wait_rekey_outbound_trigger
    when_trigger_outbound_update_set? do
      bud Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound
      hop_wait_rekey_outbound
    end

    nap 5
  end

  label def wait_rekey_outbound
    reap
    if leaf?
      decr_trigger_outbound_update
      hop_wait_rekey_old_state_drop_trigger
    end

    donate
  end

  label def wait_rekey_old_state_drop_trigger
    when_old_state_drop_trigger_set? do
      bud Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state
      hop_wait_rekey_old_state_drop
    end

    nap 5
  end

  label def wait_rekey_old_state_drop
    reap
    if leaf?
      decr_old_state_drop_trigger
      hop_wait
    end

    donate
  end

  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources") { {nic: nic.values} }
      nap 5
    end

    decr_destroy
    strand.children.each { _1.destroy }

    DB.transaction do
      nic.src_ipsec_tunnels_dataset.destroy
      nic.dst_ipsec_tunnels_dataset.destroy
      nic.private_subnet.incr_refresh_keys

      nic.destroy
    end

    pop "nic deleted"
  end

  label def detach_vm
    DB.transaction do
      nic.update(vm_id: nil)
      nic.src_ipsec_tunnels_dataset.destroy
      nic.dst_ipsec_tunnels_dataset.destroy
      nic.private_subnet.incr_refresh_keys
      strand.children.map { _1.destroy }
      decr_detach_vm
    end

    hop_wait
  end

  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here is not a formality: otherwise assigning a ipv6 link
  # local address errors out.
  def self.gen_mac
    ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
      "%0.2X" % _1
    }.join(":").downcase
  end
end
