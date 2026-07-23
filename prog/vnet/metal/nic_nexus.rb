# frozen_string_literal: true

class Prog::Vnet::Metal::NicNexus < Prog::Base
  subject_is :nic

  label def start
    when_vm_allocated_set? do
      hop_wait_setup
    end
    nap 5
  end

  label def wait_setup
    decr_vm_allocated
    when_setup_nic_set? do
      decr_setup_nic
      nic.private_subnet.incr_refresh_keys
      nic.update(state: "creating")
    end
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
    fail "BUG: unexpected start_rekey signal (retval=#{retval&.dig("msg").inspect}, phase=#{nic.rekey_phase}, locked=#{!nic.rekey_coordinator_id.nil?})" unless nic.rekey_coordinator_id && nic.rekey_phase == "idle"

    if retval&.dig("msg") == "inbound_setup is complete"
      nic.update(rekey_phase: "inbound")
      PrivateSubnet.incr_nic_phase_done(nic.rekey_coordinator_id)
      hop_wait_rekey_outbound_trigger
    end

    # RekeyNicTunnel must not modify rekey_phase or rekey_coordinator_id.
    push Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound
  end

  label def wait_rekey_outbound_trigger
    fail "BUG: NIC not locked in wait_rekey_outbound_trigger" unless nic.rekey_coordinator_id

    if retval&.dig("msg") == "outbound_setup is complete"
      fail "BUG: NIC phase should be inbound before advancing to outbound, got #{nic.rekey_phase}" unless nic.rekey_phase == "inbound"
      nic.update(rekey_phase: "outbound")
      PrivateSubnet.incr_nic_phase_done(nic.rekey_coordinator_id)
      hop_wait_rekey_old_state_drop_trigger
    end

    when_trigger_outbound_update_set? do
      decr_trigger_outbound_update
      # Looks redundant, but semaphore ordering is the only guarantee that
      # this trigger arrives while claimed and inbound; keep the guard.
      fail "BUG: unexpected trigger_outbound_update (phase=#{nic.rekey_phase}, locked=#{!nic.rekey_coordinator_id.nil?})" unless nic.rekey_phase == "inbound"
      push Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound
    end

    nap 5
  end

  label def wait_rekey_old_state_drop_trigger
    fail "BUG: NIC not locked in wait_rekey_old_state_drop_trigger" unless nic.rekey_coordinator_id

    if retval&.dig("msg")&.start_with?("drop_old_state is complete")
      fail "BUG: NIC phase should be outbound before advancing to old_drop, got #{nic.rekey_phase}" unless nic.rekey_phase == "outbound"
      nic.update(state: "active", rekey_phase: "old_drop")
      PrivateSubnet.incr_nic_phase_done(nic.rekey_coordinator_id)
      hop_wait
    end

    when_old_state_drop_trigger_set? do
      decr_old_state_drop_trigger
      # Looks redundant, but semaphore ordering is the only guarantee that
      # this trigger arrives while claimed and outbound; keep the guard.
      fail "BUG: unexpected old_state_drop_trigger (phase=#{nic.rekey_phase}, locked=#{!nic.rekey_coordinator_id.nil?})" unless nic.rekey_phase == "outbound"
      push Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state
    end

    nap 5
  end

  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources", nic)
      nap 5
    end

    decr_destroy

    nic.private_subnet.incr_refresh_keys
    # Hard-delete is load-bearing: the row vanishing from the claimed
    # set is what releases a mid-rekey NIC's coordinator claim.
    nic.destroy

    pop "nic deleted"
  end
end
