# frozen_string_literal: true

class Prog::Vnet::Metal::NicNexus < Prog::Base
  subject_is :nic

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def start
    when_vm_allocated_set? do
      hop_wait_setup
    end
    nap 5
  end

  label def wait_setup
    decr_vm_allocated
    when_setup_nic_set? do
      DB.transaction do
        decr_setup_nic
        nic.private_subnet.incr_add_new_nic
      end
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

    if retval&.dig("msg") == "inbound_setup is complete"
      hop_wait_rekey_outbound_trigger
    end

    push Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound
  end

  label def wait_rekey_outbound_trigger
    if retval&.dig("msg") == "outbound_setup is complete"
      hop_wait_rekey_old_state_drop_trigger
    end

    when_trigger_outbound_update_set? do
      decr_trigger_outbound_update
      push Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound
    end

    nap 5
  end

  label def wait_rekey_old_state_drop_trigger
    if retval&.dig("msg")&.include?("drop_old_state is complete")
      hop_wait
    end

    when_old_state_drop_trigger_set? do
      decr_old_state_drop_trigger
      push Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state
    end

    nap 5
  end

  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources") { nic }
      nap 5
    end

    decr_destroy

    nic.private_subnet.incr_refresh_keys
    nic.destroy

    pop "nic deleted"
  end
end
