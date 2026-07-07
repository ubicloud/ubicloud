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
    it "hibernates if nothing to do" do
      expect { nx.start }.to nap(60 * 60 * 24 * 365 * 1000)
    end

    it "hops to wait_setup if allocated" do
      expect(nx).to receive(:when_vm_allocated_set?).and_yield
      expect { nx.start }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    it "hibernates if nothing to do" do
      expect(nx).to receive(:decr_vm_allocated)
      expect { nx.wait_setup }.to nap(60 * 60 * 24 * 365 * 1000)
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
      expect { nx.wait_setup }.to nap(60 * 60 * 24 * 365 * 1000)
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

    it "hibernates if nothing to do" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 365 * 1000)
    end

    it "hops to start rekey if needed" do
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect { nx.wait }.to hop("start_rekey")
    end

    it "naps if repopulate is set" do
      expect(nx).to receive(:when_repopulate_set?).and_yield
      expect { nx.wait }.to nap(60 * 60 * 24 * 365 * 1000)
    end
  end

  describe "#rekey" do
    let(:nic) {
      n = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:3::",
        private_ipv4: "10.0.0.5", mac: "00:00:00:00:00:05",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "test-nic-v2", state: "active",
        rekey_coordinator_id: ps.id)
      Strand.create_with_id(n, prog: "Vnet::NicNexus", label: "start_rekey")
      n
    }
    let(:nx) { described_class.new(nic.strand) }

    before do
      ps_strand
    end

    it "pushes setup_inbound when the phase is idle" do
      expect { nx.start_rekey }.to hop(:setup_inbound, "Vnet::RekeyNicTunnel")
    end

    it "advances the phase and signals the coordinator when inbound_setup completes" do
      nic.strand.update(retval: {"msg" => "inbound_setup is complete"})
      expect { nx.start_rekey }.to hop("wait_rekey_outbound_trigger")
      expect(nic.reload.rekey_phase).to eq "inbound"
      expect(Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count).to eq 1
    end

    it "fails if inbound_setup completes when the phase is not idle" do
      nic.update(rekey_phase: "inbound")
      nic.strand.update(retval: {"msg" => "inbound_setup is complete"})
      expect { nx.start_rekey }.to raise_error(RuntimeError, "BUG: unexpected start_rekey signal (retval=\"inbound_setup is complete\", phase=inbound, locked=true)")
    end

    it "fails on an unexpected start_rekey signal" do
      nic.update(rekey_phase: "outbound")
      expect { nx.start_rekey }.to raise_error(RuntimeError, "BUG: unexpected start_rekey signal (retval=nil, phase=outbound, locked=true)")
    end

    it "fails if the nic is not locked when inbound_setup completes" do
      nic.update(rekey_coordinator_id: nil)
      nic.strand.update(retval: {"msg" => "inbound_setup is complete"})
      expect { nx.start_rekey }.to raise_error(RuntimeError, "BUG: unexpected start_rekey signal (retval=\"inbound_setup is complete\", phase=idle, locked=false)")
    end

    it "naps if outbound is not triggered" do
      nic.update(rekey_phase: "inbound")
      expect { nx.wait_rekey_outbound_trigger }.to nap(120)
    end

    it "advances the phase and signals the coordinator when outbound_setup completes" do
      nic.update(rekey_phase: "inbound")
      nic.strand.update(retval: {"msg" => "outbound_setup is complete"})
      expect { nx.wait_rekey_outbound_trigger }.to hop("wait_rekey_old_state_drop_trigger")
      expect(nic.reload.rekey_phase).to eq "outbound"
      expect(Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count).to eq 1
    end

    it "fails if outbound_setup completes when the phase is not inbound" do
      nic.strand.update(retval: {"msg" => "outbound_setup is complete"})
      expect { nx.wait_rekey_outbound_trigger }.to raise_error(RuntimeError, "BUG: NIC phase should be inbound before advancing to outbound, got idle")
    end

    it "pushes setup_outbound when outbound update is triggered" do
      nic.update(rekey_phase: "inbound")
      nic.incr_trigger_outbound_update
      expect { nx.wait_rekey_outbound_trigger }.to hop(:setup_outbound, "Vnet::RekeyNicTunnel")
      expect(nic.trigger_outbound_update_set?).to be false
    end

    it "fails on an unexpected trigger_outbound_update" do
      nic.incr_trigger_outbound_update
      expect { nx.wait_rekey_outbound_trigger }.to raise_error(RuntimeError, "BUG: unexpected trigger_outbound_update (phase=idle, locked=true)")
    end

    it "fails if the nic is not locked in wait_rekey_outbound_trigger" do
      nic.update(rekey_coordinator_id: nil)
      expect { nx.wait_rekey_outbound_trigger }.to raise_error(RuntimeError, "BUG: NIC not locked in wait_rekey_outbound_trigger")
    end

    it "naps if old state drop is not triggered" do
      nic.update(rekey_phase: "outbound")
      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(120)
    end

    it "activates the nic, advances the phase and hops to wait when drop_old_state completes" do
      nic.update(state: "creating", rekey_phase: "outbound")
      nic.strand.update(retval: {"msg" => "drop_old_state is complete"})
      expect { nx.wait_rekey_old_state_drop_trigger }.to hop("wait")
      nic.reload
      expect(nic.state).to eq "active"
      expect(nic.rekey_phase).to eq "old_drop"
      expect(Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count).to eq 1
    end

    it "fails if drop_old_state completes when the phase is not outbound" do
      nic.strand.update(retval: {"msg" => "drop_old_state is complete"})
      expect { nx.wait_rekey_old_state_drop_trigger }.to raise_error(RuntimeError, "BUG: NIC phase should be outbound before advancing to old_drop, got idle")
    end

    it "pushes drop_old_state when old state drop is triggered" do
      nic.update(rekey_phase: "outbound")
      nic.incr_old_state_drop_trigger
      expect { nx.wait_rekey_old_state_drop_trigger }.to hop(:drop_old_state, "Vnet::RekeyNicTunnel")
      expect(nic.old_state_drop_trigger_set?).to be false
    end

    it "fails on an unexpected old_state_drop_trigger" do
      nic.incr_old_state_drop_trigger
      expect { nx.wait_rekey_old_state_drop_trigger }.to raise_error(RuntimeError, "BUG: unexpected old_state_drop_trigger (phase=idle, locked=true)")
    end

    it "fails if the nic is not locked in wait_rekey_old_state_drop_trigger" do
      nic.update(rekey_coordinator_id: nil)
      expect { nx.wait_rekey_old_state_drop_trigger }.to raise_error(RuntimeError, "BUG: NIC not locked in wait_rekey_old_state_drop_trigger")
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
