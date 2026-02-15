# frozen_string_literal: true

class Prog::Vnet::Metal::NicNexus < Prog::Base
  subject_is :nic

  # TLA:module SubnetRekey

  label def start
    when_vm_allocated_set? do
      hop_wait_setup
    end
    nap 5
  end

  # TLA \* CreateNic: activate an inactive NIC.  Sets refreshNeeded on owner.
  # TLA \* Models wait_setup: decr_setup_nic + incr_refresh_keys + state "creating".
  # TLA CreateNic(n) ==
  # TLA   ∧ n ∈ AllNics \ activeNics
  # TLA   ∧ ops < MaxOps
  label def wait_setup
    decr_vm_allocated
    when_setup_nic_set? do
      DB.transaction do
        decr_setup_nic
        # TLA   ∧ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = TRUE]
        nic.private_subnet.incr_refresh_keys
        # TLA   ∧ activeNics' = activeNics ∪ {n}
        nic.update(state: "creating")
      end
    end
    # TLA   ∧ ops' = ops + 1
    # TLA   ∧ UNCHANGED ⟨edges, pc, heldLocks, nicPhase⟩
    # TLA
    when_start_rekey_set? do
      hop_start_rekey
    end
    nap 5
  end

  label def wait
    when_repopulate_set? do
      nic.private_subnet.incr_refresh_keys
      decr_repopulate
    end

    when_start_rekey_set? do
      hop_start_rekey
    end

    nap 6 * 60 * 60
  end

  label def start_rekey
    decr_start_rekey

    # TLA \* NicAdvanceInbound: idle → inbound (after setup_inbound).
    # TLA NicAdvanceInbound(n) ==
    # TLA   ∧ n ∈ activeNics
    # TLA   ∧ nicPhase[n] = "idle"
    # TLA   ∧ ∃ s ∈ Subnets : n ∈ heldLocks[s] ∧ pc[s] = "phase_inbound"
    if retval&.dig("msg") == "inbound_setup is complete"
      fail "BUG: NIC not locked for rekey" unless nic.rekey_coordinator_id
      fail "BUG: NIC phase should be idle before advancing to inbound, got #{nic.rekey_phase}" unless nic.rekey_phase == "idle"
      # TLA   ∧ nicPhase' = [nicPhase EXCEPT ![n] = "inbound"]
      nic.update(rekey_phase: "inbound")
      # TLA   ∧ UNCHANGED ⟨edges, pc, heldLocks, ops, activeNics, refreshNeeded⟩
      # TLA
      hop_wait_rekey_outbound_trigger
    end

    fail "BUG: NIC not locked at start_rekey entry" unless nic.rekey_coordinator_id
    push Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound
  end

  label def wait_rekey_outbound_trigger
    fail "BUG: NIC not locked in wait_rekey_outbound_trigger" unless nic.rekey_coordinator_id

    # TLA \* NicAdvanceOutbound: inbound → outbound (after setup_outbound).
    # TLA NicAdvanceOutbound(n) ==
    # TLA   ∧ n ∈ activeNics
    # TLA   ∧ nicPhase[n] = "inbound"
    # TLA   ∧ ∃ s ∈ Subnets : n ∈ heldLocks[s] ∧ pc[s] = "phase_outbound"
    if retval&.dig("msg") == "outbound_setup is complete"
      fail "BUG: NIC phase should be inbound before advancing to outbound, got #{nic.rekey_phase}" unless nic.rekey_phase == "inbound"
      # TLA   ∧ nicPhase' = [nicPhase EXCEPT ![n] = "outbound"]
      nic.update(rekey_phase: "outbound")
      # TLA   ∧ UNCHANGED ⟨edges, pc, heldLocks, ops, activeNics, refreshNeeded⟩
      # TLA
      hop_wait_rekey_old_state_drop_trigger
    end

    when_trigger_outbound_update_set? do
      decr_trigger_outbound_update
      push Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound
    end

    nap 5
  end

  label def wait_rekey_old_state_drop_trigger
    fail "BUG: NIC not locked in wait_rekey_old_state_drop_trigger" unless nic.rekey_coordinator_id

    # TLA \* NicAdvanceOldDrop: outbound → old_drop (after drop_old_state).
    # TLA NicAdvanceOldDrop(n) ==
    # TLA   ∧ n ∈ activeNics
    # TLA   ∧ nicPhase[n] = "outbound"
    # TLA   ∧ ∃ s ∈ Subnets : n ∈ heldLocks[s] ∧ pc[s] = "phase_old_drop"
    if retval&.dig("msg")&.start_with?("drop_old_state is complete")
      fail "BUG: NIC phase should be outbound before advancing to old_drop, got #{nic.rekey_phase}" unless nic.rekey_phase == "outbound"
      # TLA   ∧ nicPhase' = [nicPhase EXCEPT ![n] = "old_drop"]
      nic.update(state: "active", rekey_phase: "old_drop")
      # TLA   ∧ UNCHANGED ⟨edges, pc, heldLocks, ops, activeNics, refreshNeeded⟩
      # TLA
      hop_wait
    end

    when_old_state_drop_trigger_set? do
      decr_old_state_drop_trigger
      push Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state
    end

    nap 5
  end

  # TLA \* DestroyNic: deactivate an active NIC.  Removes from heldLocks (FK cascade).
  # TLA \* Models destroy: nic.destroy + incr_refresh_keys.
  # TLA DestroyNic(n) ==
  # TLA   ∧ n ∈ activeNics
  # TLA   ∧ ops < MaxOps
  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources", nic)
      nap 5
    end

    decr_destroy

    # TLA   ∧ refreshNeeded' = [refreshNeeded EXCEPT ![NicOwner[n]] = TRUE]
    nic.private_subnet.incr_refresh_keys
    # TLA   ∧ activeNics' = activeNics \ {n}
    # TLA   ∧ heldLocks' = [s ∈ Subnets ↦ heldLocks[s] \ {n}]
    # TLA   ∧ nicPhase' = [nicPhase EXCEPT ![n] = "idle"]
    nic.destroy
    # TLA   ∧ ops' = ops + 1
    # TLA   ∧ UNCHANGED ⟨edges, pc⟩
    # TLA

    pop "nic deleted"
  end
end
