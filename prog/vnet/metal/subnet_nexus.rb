# frozen_string_literal: true

class Prog::Vnet::Metal::SubnetNexus < Prog::Base
  subject_is :private_subnet

  def before_run
    super unless destroy_set? && !locked_nics_dataset.empty?
  end

  def connected_leader?
    private_subnet.connected_leader_id == private_subnet.id
  end

  label def start
    hop_wait
  end

  label def wait
    fail "BUG: locks held while in wait (NoOrphanedLocks)" unless locked_nics_dataset.empty?

    if refresh_keys_set? && !connected_leader?
      Clog.emit("SubnetNexus forwarding refresh_keys to leader",
        {subnet_rekey_forward: {subnet_id: private_subnet.id,
                                connected_leader_id: private_subnet.connected_leader_id}})
      decr_refresh_keys
      PrivateSubnet.incr_refresh_keys(private_subnet.connected_leader_id)
      nap 0
    end

    when_refresh_keys_set? do
      Clog.emit("SubnetNexus consuming refresh_keys as leader",
        {subnet_rekey_entry: {
          subnet_id: private_subnet.id,
          last_rekey_at: private_subnet.last_rekey_at.iso8601,
          connected_leader: connected_leader?.to_s,
        }})
      decr_refresh_keys
      register_deadline("wait", 30 * 60)
      hop_refresh_keys
    end

    when_update_firewall_rules_set? do
      Vm.incr_update_firewall_rules(private_subnet.vms_dataset.select(Sequel[:vm][:id]))
      decr_update_firewall_rules
    end

    if connected_leader? && private_subnet.last_rekey_at < Time.now - 60 * 60 * 24
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

  # All locked NICs were destroyed mid-rekey: abort the pass back to idle.
  def abort_rekey_if_no_nics(nics)
    return unless nics.empty?
    Clog.emit("All locked NICs destroyed during rekey, aborting")
    private_subnet.update(state: "waiting")
    hop_wait
  end

  def check_nic_phases(nics, expected_phases, message)
    bad = nics.reject { |n| expected_phases.include?(n.rekey_phase) }
    fail "BUG: #{message}: #{bad.map { "#{it.id}=#{it.rekey_phase}" }}" if bad.any?
  end

  label def refresh_keys
    fail "BUG: locks held at idle" unless locked_nics_dataset.empty?
    nics = nics_to_rekey.order(:id).for_update.all

    # Topology changed since the signal was consumed and this subnet is
    # no longer the leader. Re-enqueue so wait forwards to the leader.
    unless connected_leader?
      private_subnet.incr_refresh_keys
      hop_wait
    end

    # Leader, but no NICs in the component: nothing to rekey, no
    # re-enqueue. NIC creation signals refresh_keys when one appears.
    if nics.empty?
      private_subnet.update(last_rekey_at: Time.now)
      hop_wait
    end

    # Another coordinator holds claims on these NICs. Park here and
    # retry: the claims clear when that coordinator's pass completes.
    # Re-enqueueing would spin through wait until then.
    nap 10 if nics.any?(&:rekey_coordinator_id)

    claimed = Nic.where(id: nics.map(&:id), rekey_coordinator_id: nil)
      .update(rekey_coordinator_id: private_subnet.id)
    # :nocov:
    # Structurally unreachable: the lock check above verifies rekey_coordinator_id is nil
    # on the same set, within the same transaction, under FOR UPDATE row locks.
    fail "BUG: locked #{claimed}/#{nics.count} NICs" unless claimed == nics.count
    # :nocov:

    check_nic_phases(nics, %w[idle], "freshly locked NICs should all be idle")

    nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key,
        rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid, esn: true})
      private_subnet.create_tunnels(nics, nic)
    end
    Nic.incr_start_rekey(nics.map(&:id))

    private_subnet.update(state: "refreshing_keys")
    hop_wait_inbound_setup
  end

  label def wait_inbound_setup
    nics = locked_nics
    abort_rekey_if_no_nics(nics)
    check_nic_phases(nics, %w[idle inbound], "phase monotonicity at phase_inbound")
    if nics.all? { |nic| nic.rekey_phase == "inbound" }
      Nic.incr_trigger_outbound_update(nics.map(&:id))
      hop_wait_outbound_setup
    end

    when_nic_phase_done_set? do
      decr_nic_phase_done
    end
    nap 120
  end

  label def wait_outbound_setup
    nics = locked_nics
    abort_rekey_if_no_nics(nics)
    check_nic_phases(nics, %w[inbound outbound], "phase monotonicity at phase_outbound")
    if nics.all? { |nic| nic.rekey_phase == "outbound" }
      Nic.incr_old_state_drop_trigger(nics.map(&:id))
      hop_wait_old_state_drop
    end

    when_nic_phase_done_set? do
      decr_nic_phase_done
    end
    nap 120
  end

  label def wait_old_state_drop
    nics = locked_nics
    abort_rekey_if_no_nics(nics)
    check_nic_phases(nics, %w[outbound old_drop], "phase monotonicity at phase_old_drop")
    if nics.all? { |nic| nic.rekey_phase == "old_drop" }
      PrivateSubnet.where(id: (nics.map(&:private_subnet_id) << private_subnet.id).uniq).update(last_rekey_at: Sequel::CURRENT_TIMESTAMP)
      private_subnet.update(state: "waiting")
      # Must stay one atomic UPDATE: clearing the claim and resetting the
      # phase together is what releases the NICs consistently.
      locked_nics_dataset.update(encryption_key: nil, rekey_payload: nil,
        rekey_coordinator_id: nil, rekey_phase: "idle")
      hop_wait
    end

    when_nic_phase_done_set? do
      decr_nic_phase_done
    end
    nap 120
  end

  label def destroy
    fail "BUG: locks held at destroy" unless locked_nics_dataset.empty?

    if private_subnet.nics.any?(&:vm_id)
      unless Semaphore.where(strand_id: private_subnet.nics.filter_map(&:vm_id), name: "prevent_destroy").empty?
        register_deadline(nil, 10 * 60, allow_extension: true)
      end

      Clog.emit("Cannot destroy subnet with active nics, first clean up the attached resources", private_subnet)

      nap 5
    end
    register_deadline(nil, 10 * 60)
    decr_destroy
    private_subnet.remove_all_firewalls

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

  REKEY_ACTIVE_STATES = %w[active creating].freeze

  def nics_to_rekey
    nics_with_state(REKEY_ACTIVE_STATES)
  end

  def locked_nics
    locked_nics_dataset.all
  end

  def locked_nics_dataset
    Nic.where(rekey_coordinator_id: private_subnet.id)
  end

  private

  def all_connected_nics
    private_subnet.find_all_connected_nics
  end

  def nics_with_state(state)
    all_connected_nics.where(state:)
  end
end
