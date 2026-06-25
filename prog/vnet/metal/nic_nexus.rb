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
    push Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound, next_label: "wait_rekey_outbound_trigger"
  end

  label def wait_rekey_outbound_trigger
    when_trigger_outbound_update_set? do
      decr_trigger_outbound_update
      push Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound, next_label: "wait_rekey_old_state_drop_trigger"
    end

    nap 5
  end

  label def wait_rekey_old_state_drop_trigger
    when_old_state_drop_trigger_set? do
      decr_old_state_drop_trigger
      push Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state, next_label: "rekey_finished"
    end

    nap 5
  end

  label def rekey_finished
    nic.update(state: "active") unless nic.state == "active"
    hop_wait
  end

  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources", nic)
      nap 5
    end

    decr_destroy

    nic.private_subnet.incr_refresh_keys
    nic.destroy

    pop "nic deleted"
  end
end
