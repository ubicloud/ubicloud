# frozen_string_literal: true

class Prog::Vnet::Metal::SubnetNexus < Prog::Base
  subject_is :private_subnet

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        register_deadline(nil, 10 * 60)
        hop_destroy
      end
    end
  end

  label def start
    hop_wait
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
      private_subnet.vms.each(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end

    if private_subnet.last_rekey_at < Time.now - 60 * 60 * 24
      private_subnet.incr_refresh_keys
    end

    nap 10 * 60
  end

  def gen_encryption_key
    "0x" + SecureRandom.bytes(36).unpack1("H*")
  end

  def gen_spi
    "0x" + SecureRandom.bytes(4).unpack1("H*")
  end

  def gen_reqid
    SecureRandom.random_number(1...100000)
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
    nics = active_nics
    nap 10 if nics.any? { |nic| nic.lock_set? }
    nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key, rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      nic.incr_lock
    end

    decr_refresh_keys
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
