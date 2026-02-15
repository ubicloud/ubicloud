# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe Prog::Vnet::Metal::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:project) { Project.create(name: "test") }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id)
  }
  let(:ps_strand) { Strand.create_with_id(ps, prog: "Vnet::SubnetNexus", label: "wait") }

  describe "#start" do
    it "naps if nothing to do" do
      expect { nx.start }.to nap(5)
    end

    it "hops to wait_setup if allocated" do
      expect(nx).to receive(:when_vm_allocated_set?).and_yield
      expect { nx.start }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    it "naps if nothing to do" do
      expect(nx).to receive(:decr_vm_allocated)
      expect { nx.wait_setup }.to nap(5)
    end

    it "incrs refresh_keys when setup_nic is set" do
      ps_strand  # ensure strand exists for semaphore
      nic = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1", mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-setup", state: "initializing")

      expect(nx).to receive(:nic).and_return(nic).at_least(:once)
      expect(nx).to receive(:decr_vm_allocated)
      expect(nx).to receive(:when_setup_nic_set?).and_yield
      expect(nx).to receive(:decr_setup_nic)
      expect { nx.wait_setup }.to nap(5)
      expect(nic.reload.state).to eq("creating")
      expect(Semaphore.where(strand_id: ps.id, name: "refresh_keys").count).to eq(1)
    end

    it "starts rekeying if setup is triggered" do
      expect(nx).to receive(:decr_vm_allocated)
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect { nx.wait_setup }.to hop("start_rekey")
    end
  end

  describe "#wait" do
    let(:nic) {
      Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
        private_ipv4: "10.0.0.2", mac: "00:00:00:00:00:01",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-wait", state: "active")
    }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "naps if nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to start rekey if needed" do
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect { nx.wait }.to hop("start_rekey")
    end

    it "hops to repopulate if needed" do
      expect(nx).to receive(:when_repopulate_set?).and_yield
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#rekey" do
    let(:nic) {
      Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:1::",
        private_ipv4: "10.0.0.3", mac: "00:00:00:00:00:02",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-rekey", state: "active",
        rekey_coordinator_id: ps.id)
    }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "pushes rekey with setup_inbound and naps" do
      expect(nx).to receive(:push).with(Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound)
      nx.start_rekey
    end

    it "hops to wait_rekey_outbound_trigger if inbound_setup is completed" do
      expect(nx).to receive(:retval).and_return({"msg" => "inbound_setup is complete"})
      expect(nx).to receive(:decr_start_rekey)
      expect { nx.start_rekey }.to hop("wait_rekey_outbound_trigger")
      expect(nic.reload.rekey_phase).to eq("inbound")
    end

    it "fails if NIC not locked at start_rekey entry" do
      nic.update(rekey_coordinator_id: nil)
      nic_strand = Strand.create_with_id(nic, prog: "Vnet::Metal::NicNexus", label: "start_rekey")
      nic.incr_start_rekey
      expect { nic_strand.unsynchronized_run }.to raise_error RuntimeError, /unexpected start_rekey signal/
    end

    it "fails if NIC not locked when advancing to inbound" do
      nic.update(rekey_coordinator_id: nil)
      expect(nx).to receive(:retval).and_return({"msg" => "inbound_setup is complete"})
      expect(nx).to receive(:decr_start_rekey)
      expect { nx.start_rekey }.to raise_error RuntimeError, /NIC not locked for rekey/
    end

    it "fails if NIC phase is not idle when advancing to inbound" do
      nic.update(rekey_phase: "inbound")
      expect(nx).to receive(:retval).and_return({"msg" => "inbound_setup is complete"})
      expect(nx).to receive(:decr_start_rekey)
      expect { nx.start_rekey }.to raise_error RuntimeError, /phase should be idle before advancing to inbound/
    end

    it "if outbound setup is not triggered, just naps" do
      nic.update(rekey_phase: "inbound")
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_return(false)
      expect { nx.wait_rekey_outbound_trigger }.to nap(5)
    end

    it "if outbound setup is triggered, pushes setup_outbound and naps" do
      nic.update(rekey_phase: "inbound")
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_yield
      expect(nx).to receive(:decr_trigger_outbound_update)
      expect(nx).to receive(:push).with(Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound)
      expect { nx.wait_rekey_outbound_trigger }.to nap(5)
    end

    it "fails if NIC phase is wrong when trigger_outbound_update fires" do
      nic_strand = Strand.create_with_id(nic, prog: "Vnet::Metal::NicNexus", label: "wait_rekey_outbound_trigger")
      nic.incr_trigger_outbound_update
      expect { nic_strand.unsynchronized_run }.to raise_error RuntimeError, /unexpected trigger_outbound_update/
    end

    it "fails if NIC not locked in wait_rekey_outbound_trigger" do
      nic.update(rekey_coordinator_id: nil, rekey_phase: "inbound")
      expect { nx.wait_rekey_outbound_trigger }.to raise_error RuntimeError, /NIC not locked in wait_rekey_outbound_trigger/
    end

    it "fails if NIC phase is not inbound when advancing to outbound" do
      nic.update(rekey_phase: "idle")
      expect(nx).to receive(:retval).and_return({"msg" => "outbound_setup is complete"})
      expect { nx.wait_rekey_outbound_trigger }.to raise_error RuntimeError, /phase should be inbound before advancing to outbound/
    end

    it "hops to wait_rekey_old_state_drop_trigger if outbound_setup is completed" do
      nic.update(rekey_phase: "inbound")
      expect(nx).to receive(:retval).and_return({"msg" => "outbound_setup is complete"})
      expect { nx.wait_rekey_outbound_trigger }.to hop("wait_rekey_old_state_drop_trigger")
      expect(nic.reload.rekey_phase).to eq("outbound")
    end

    it "wait_rekey_old_state_drop_trigger naps if trigger is not set" do
      nic.update(rekey_phase: "outbound")
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_return(false)

      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(5)
    end

    it "wait_rekey_old_state_drop_trigger pushes drop_old_state and naps if trigger is set" do
      nic.update(rekey_phase: "outbound")
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_yield
      expect(nx).to receive(:decr_old_state_drop_trigger)
      expect(nx).to receive(:push).with(Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state)
      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(5)
    end

    it "fails if NIC phase is wrong when old_state_drop_trigger fires" do
      nic_strand = Strand.create_with_id(nic, prog: "Vnet::Metal::NicNexus", label: "wait_rekey_old_state_drop_trigger")
      nic.incr_old_state_drop_trigger
      expect { nic_strand.unsynchronized_run }.to raise_error RuntimeError, /unexpected old_state_drop_trigger/
    end

    it "fails if NIC not locked in wait_rekey_old_state_drop_trigger" do
      nic.update(rekey_coordinator_id: nil, rekey_phase: "outbound")
      expect { nx.wait_rekey_old_state_drop_trigger }.to raise_error RuntimeError, /NIC not locked in wait_rekey_old_state_drop_trigger/
    end

    it "fails if NIC phase is not outbound when advancing to old_drop" do
      nic.update(rekey_phase: "inbound")
      expect(nx).to receive(:retval).and_return({"msg" => "drop_old_state is complete"})
      expect { nx.wait_rekey_old_state_drop_trigger }.to raise_error RuntimeError, /phase should be outbound before advancing to old_drop/
    end

    it "hops to wait if drop_old_state is completed, updates state and rekey_phase" do
      expect(nx).to receive(:retval).and_return({"msg" => "drop_old_state is complete"})
      nic.update(state: "creating", rekey_phase: "outbound")
      expect { nx.wait_rekey_old_state_drop_trigger }.to hop("wait")
      nic.reload
      expect(nic.state).to eq("active")
      expect(nic.rekey_phase).to eq("old_drop")
    end
  end

  describe "#destroy" do
    let(:destroy_project) { Project.create(name: "destroy-test") }
    let(:destroy_ps) {
      PrivateSubnet.create(name: "destroy-ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fcc::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: destroy_project.id)
    }
    let(:destroy_ps_strand) { Strand.create_with_id(destroy_ps, prog: "Vnet::SubnetNexus", label: "wait") }
    let(:nic) {
      Nic.create(private_subnet_id: destroy_ps.id, private_ipv6: "fd10:9b0b:6b4b:8fcc:abc::",
        private_ipv4: "1.1.1.1", mac: "00:00:00:00:00:03",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-destroy", state: "active")
    }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "destroys nic" do
      destroy_ps_strand  # ensure strand exists for semaphore
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
      expect(nic.exists?).to be false
      expect(Semaphore.where(strand_id: destroy_ps.id, name: "refresh_keys").count).to eq(1)
    end

    it "clears rekey lock on coordinator when destroyed" do
      destroy_ps_strand
      nic.update(rekey_coordinator_id: destroy_ps.id)
      expect(Nic.where(rekey_coordinator_id: destroy_ps.id).count).to eq(1)
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
      expect(Nic.where(rekey_coordinator_id: destroy_ps.id).count).to eq(0)
    end

    it "fails if there is vm attached" do
      vm = create_vm(project_id: destroy_project.id)
      nic.update(vm_id: vm.id)
      expect { nx.destroy }.to nap(5)
    end
  end

  describe "nic fetch" do
    let(:fetch_nic) {
      Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:2::",
        private_ipv4: "10.0.0.4", mac: "00:00:00:00:00:04",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-fetch", state: "active")
    }

    before do
      nx.instance_variable_set(:@nic, fetch_nic)
    end

    it "returns nic" do
      expect(nx.nic).to eq(fetch_nic)
    end
  end
end
