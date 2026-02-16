# frozen_string_literal: true

class Prog::Vnet::Metal::SubnetNexus < Prog::Base
  subject_is :private_subnet

  # TLA:module SubnetRekey
  # TLA \* Destroy guard: subnet cannot be destroyed while heldLocks[s] ≠ {}.
  # TLA \* Proof-critical for NoOrphanedLocks invariant.
  def before_run
    super unless destroy_set? && !locked_nics_dataset.empty?
  end

  def connected_leader?
    private_subnet.connected_leader_id == private_subnet.id
  end

  label def start
    hop_wait
  end

  # TLA \* ForwardRefreshKeys: non-leader forwards refreshNeeded to leader.
  # TLA \* Models wait: decr_refresh_keys + connected_leader.incr_refresh_keys.
  # TLA ForwardRefreshKeys(s) ==
  # TLA   ∧ pc[s] = "idle"
  label def wait
    fail "BUG: locks held while in wait (NoOrphanedLocks)" unless locked_nics_dataset.empty?

    # TLA   ∧ refreshNeeded[s] > 0
    when_refresh_keys_set? do
      remaining_refresh = private_subnet.semaphores.count { it.name == "refresh_keys" }
      Clog.emit("SubnetNexus entering refresh_keys",
        {subnet_rekey_entry: {
          subnet_id: private_subnet.id,
          last_rekey_at: private_subnet.last_rekey_at.iso8601,
          remaining_refresh_keys_semaphores: remaining_refresh,
          connected_leader: connected_leader?.to_s
        }})
      decr_refresh_keys
      # TLA   ∧ ConnectedLeader(s) ≠ s
      unless connected_leader?
        # TLA   ∧ refreshNeeded' = [refreshNeeded EXCEPT ![s] = 0, ![ConnectedLeader(s)] = @ + 1]
        # TLA   ∧ UNCHANGED ⟨edges, pc, heldLocks, ops, nicPhase, activeNics⟩
        # TLA
        PrivateSubnet[private_subnet.connected_leader_id].incr_refresh_keys
        nap 0
      end

      hop_refresh_keys
    end

    when_update_firewall_rules_set? do
      private_subnet.vms.each(&:incr_update_firewall_rules)
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

  # TLA \* ReadAndLock: idle → refresh_keys.  Acquire NIC row locks (FOR UPDATE).
  # TLA \* FOR UPDATE does not lock topology tables; ConnectedLeader can change
  # TLA \* before ClaimOrBail re-checks leadership.
  # TLA \* Note: refreshNeeded' consumed earlier in wait:decr_refresh_keys.
  # TLA ReadAndLock(s) ==
  # TLA   ∧ pc[s] = "idle"
  # TLA   ∧ ConnectedLeader(s) = s
  # TLA   ∧ refreshNeeded[s] > 0
  # TLA   ∧ LET nics == AllConnectedNics(s)
  # TLA     IN ∧ ∀ n ∈ nics : ¬IsLocked(n)
  # TLA        ∧ heldLocks' = [heldLocks EXCEPT ![s] = nics]
  # TLA   ∧ refreshNeeded' = [refreshNeeded EXCEPT ![s] = 0]
  # TLA   ∧ pc' = [pc EXCEPT ![s] = "refresh_keys"]
  # TLA   ∧ UNCHANGED ⟨edges, ops, nicPhase, activeNics⟩
  # TLA
  # TLA \* ClaimOrBail: refresh_keys → phase_inbound (proceed) or idle (bail).
  # TLA \* Re-checks leadership post-lock; topology may have changed since ReadAndLock.
  # TLA ClaimOrBail(s) ==
  # TLA   ∧ pc[s] = "refresh_keys"
  # TLA   ∧ IF ConnectedLeader(s) = s ∧ heldLocks[s] ≠ {}
  # TLA     THEN ∧ pc' = [pc EXCEPT ![s] = "phase_inbound"]
  # TLA          ∧ UNCHANGED ⟨heldLocks, refreshNeeded⟩
  # TLA     ELSE ∧ heldLocks' = [heldLocks EXCEPT ![s] = {}]
  # TLA          ∧ pc' = [pc EXCEPT ![s] = "idle"]
  # TLA          ∧ refreshNeeded' = IF ConnectedLeader(s) ≠ s
  # TLA                              THEN [refreshNeeded EXCEPT ![s] = @ + 1]
  # TLA                              ELSE refreshNeeded
  # TLA   ∧ UNCHANGED ⟨edges, ops, nicPhase, activeNics⟩
  # TLA
  label def refresh_keys
    fail "BUG: locks held at idle" unless locked_nics_dataset.empty?

    # Proof: ReadAndLock — FOR UPDATE provides atomicity.
    # Removing this breaks MutualExclusion (see skip-write-recheck mutation).
    nics = nics_to_rekey.order(:id).for_update.all

    # Proof: ClaimOrBail — re-check leadership post-lock.
    # Topology may have changed since wait; re-enqueue for the actual leader.
    unless connected_leader?
      private_subnet.incr_refresh_keys
      hop_wait
    end

    if nics.empty?
      hop_wait
    end

    if nics.any?(&:rekey_coordinator_id)
      hop_wait
    end

    claimed = Nic.where(id: nics.map(&:id), rekey_coordinator_id: nil)
      .update(rekey_coordinator_id: private_subnet.id)
    # :nocov:
    # Structurally unreachable: the lock check above verifies rekey_coordinator_id is nil
    # on the same set, within the same transaction, under FOR UPDATE row locks.
    fail "BUG: locked #{claimed}/#{nics.count} NICs" unless claimed == nics.count
    # :nocov:

    bad_phase = nics.reject { |n| n.rekey_phase == "idle" }
    fail "BUG: freshly locked NICs should all be idle: #{bad_phase.map { "#{it.id}=#{it.rekey_phase}" }}" if bad_phase.any?

    nics.each do |nic|
      nic.update(encryption_key: gen_encryption_key,
        rekey_payload: {spi4: gen_spi, spi6: gen_spi, reqid: gen_reqid})
      nic.incr_start_rekey
      private_subnet.create_tunnels(nics, nic)
    end

    private_subnet.update(state: "refreshing_keys")
    hop_wait_inbound_setup
  end

  # TLA \* AdvanceInbound: all locked NICs at "inbound" → advance to outbound.
  # TLA \* Models wait_inbound_setup: checks rekey_phase, triggers outbound.
  # TLA AdvanceInbound(s) ==
  # TLA   ∧ pc[s] = "phase_inbound"
  label def wait_inbound_setup
    nics = locked_nics
    # TLA   ∧ heldLocks[s] ≠ {}
    if nics.empty?
      # AbortRekey: all locked NICs destroyed mid-rekey → abort to idle.
      Clog.emit("All locked NICs destroyed during rekey, aborting")
      private_subnet.update(state: "waiting")
      hop_wait
    end
    bad = nics.reject { |n| %w[idle inbound].include?(n.rekey_phase) }
    fail "BUG: phase monotonicity at phase_inbound: #{bad.map { "#{it.id}=#{it.rekey_phase}" }}" if bad.any?
    # TLA   ∧ ∀ n ∈ heldLocks[s] : nicPhase[n] = "inbound"
    if nics.all? { |nic| nic.rekey_phase == "inbound" }
      nics.each(&:incr_trigger_outbound_update)
      # TLA   ∧ pc' = [pc EXCEPT ![s] = "phase_outbound"]
      # TLA   ∧ UNCHANGED ⟨edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded⟩
      # TLA
      hop_wait_outbound_setup
    end

    nap 5
  end

  # TLA \* AdvanceOutbound: all locked NICs at "outbound" → advance to old_drop.
  # TLA \* Models wait_outbound_setup: checks rekey_phase, triggers old_drop.
  # TLA AdvanceOutbound(s) ==
  # TLA   ∧ pc[s] = "phase_outbound"
  label def wait_outbound_setup
    nics = locked_nics
    # TLA   ∧ heldLocks[s] ≠ {}
    if nics.empty?
      # AbortRekey: all locked NICs destroyed mid-rekey → abort to idle.
      Clog.emit("All locked NICs destroyed during rekey, aborting")
      private_subnet.update(state: "waiting")
      hop_wait
    end
    bad = nics.reject { |n| %w[inbound outbound].include?(n.rekey_phase) }
    fail "BUG: phase monotonicity at phase_outbound: #{bad.map { "#{it.id}=#{it.rekey_phase}" }}" if bad.any?
    # TLA   ∧ ∀ n ∈ heldLocks[s] : nicPhase[n] = "outbound"
    if nics.all? { |nic| nic.rekey_phase == "outbound" }
      nics.each(&:incr_old_state_drop_trigger)
      # TLA   ∧ pc' = [pc EXCEPT ![s] = "phase_old_drop"]
      # TLA   ∧ UNCHANGED ⟨edges, heldLocks, ops, nicPhase, activeNics, refreshNeeded⟩
      # TLA
      hop_wait_old_state_drop
    end

    nap 5
  end

  # TLA \* FinishRekey: phase_old_drop → idle.  Barrier + release all held locks.
  # TLA \* Resets nicPhase to "idle" for all locked NICs, then releases locks.
  # TLA FinishRekey(s) ==
  # TLA   ∧ pc[s] = "phase_old_drop"
  label def wait_old_state_drop
    nics = locked_nics
    # TLA   ∧ heldLocks[s] ≠ {}
    if nics.empty?
      # AbortRekey: all locked NICs destroyed mid-rekey → abort to idle.
      Clog.emit("All locked NICs destroyed during rekey, aborting")
      private_subnet.update(state: "waiting")
      hop_wait
    end
    bad = nics.reject { |n| %w[outbound old_drop].include?(n.rekey_phase) }
    fail "BUG: phase monotonicity at phase_old_drop: #{bad.map { "#{it.id}=#{it.rekey_phase}" }}" if bad.any?
    # TLA   ∧ ∀ n ∈ heldLocks[s] : nicPhase[n] = "old_drop"
    if nics.all? { |nic| nic.rekey_phase == "old_drop" }
      PrivateSubnet.where(id: nics.map(&:private_subnet_id).uniq).update(last_rekey_at: Time.now)
      private_subnet.update(state: "waiting")
      # TLA   ∧ nicPhase' = [n ∈ AllNics ↦ IF n ∈ heldLocks[s] THEN "idle" ELSE nicPhase[n]]
      # TLA   ∧ heldLocks' = [heldLocks EXCEPT ![s] = {}]
      # Proof-critical for NicPhaseProgress and LocksEventuallyReleased:
      # resets phase to idle and clears coordinator FK in one atomic UPDATE.
      locked_nics_dataset.update(encryption_key: nil, rekey_payload: nil,
        rekey_coordinator_id: nil, rekey_phase: "idle")
      # TLA   ∧ pc' = [pc EXCEPT ![s] = "idle"]
      # TLA   ∧ UNCHANGED ⟨edges, ops, activeNics, refreshNeeded⟩
      # TLA
      hop_wait
    end

    nap 5
  end

  # TLA \* Destroy: remove all edges of s, signal neighbors (must be idle with no locks).
  # TLA \* Models destroy: disconnect_subnet (incr_refresh_keys on both sides) + destroy.
  # TLA Destroy(s) ==
  # TLA   ∧ pc[s] = "idle"
  # TLA   ∧ heldLocks[s] = {}
  # TLA   ∧ ops < MaxOps
  # TLA   ∧ LET nbrs == Neighbors(s)
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

    # TLA     IN ∧ edges' = {e ∈ edges : e[1] ≠ s ∧ e[2] ≠ s}
    private_subnet.connected_subnets.each do |subnet|
      private_subnet.disconnect_subnet(subnet)
    end

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      # TLA        ∧ refreshNeeded' = [t ∈ Subnets ↦
      # TLA            IF t ∈ nbrs THEN refreshNeeded[t] + 1 ELSE refreshNeeded[t]]
      # TLA        ∧ ops' = ops + 1
      # TLA        ∧ UNCHANGED ⟨pc, heldLocks, nicPhase, activeNics⟩
      # TLA
      private_subnet.destroy
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap rand(5..10)
    end
  end

  # Proof: corresponds to TLA+ activeNics. Adding new NIC states here
  # requires updating the proof's InitActiveNics and CreateNic.
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
