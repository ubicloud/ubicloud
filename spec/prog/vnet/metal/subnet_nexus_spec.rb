# frozen_string_literal: true

RSpec.describe Prog::Vnet::Metal::SubnetNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:prj) { Project.create(name: "default") }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
  }
  let(:st) { Strand.create(id: ps.id, prog: "Vnet::Metal::SubnetNexus", label: "start") }

  let(:ps2) {
    PrivateSubnet.create(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fcc::/64",
      net4: "1.1.1.128/26", state: "waiting", project_id: prj.id)
  }

  let(:leader_ps) {
    PrivateSubnet.create_with_id("00000000-0000-0000-0000-000000000001", name: "ps-leader",
      location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fdd::/64",
      net4: "1.1.2.0/26", state: "waiting", project_id: prj.id, rekey_protocol: 2)
  }

  describe ".gen_spi" do
    let(:nx) { described_class.new(Strand.new) }

    it "generates a random spi" do
      expect(SecureRandom).to receive(:bytes).with(4).and_return("e3af3a04")
      expect(nx.gen_spi).to eq("0x6533616633613034")
    end
  end

  describe ".gen_reqid" do
    let(:nx) { described_class.new(Strand.new) }

    it "generates a random reqid" do
      expect(SecureRandom).to receive(:random_number).with(1...100000).and_return(10)
      expect(nx.gen_reqid).to eq(10)
    end
  end

  describe ".gen_encryption_key" do
    let(:nx) { described_class.new(Strand.new) }

    it "generates a random encryption key" do
      expect(SecureRandom).to receive(:bytes).with(36).and_return("e3af3a04")
      expect(nx.gen_encryption_key).to eq("0x6533616633613034")
    end
  end

  describe ".nics_to_rekey" do
    it "returns nics that need rekeying" do
      nic1 = Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject
      nic2 = Prog::Vnet::NicNexus.assemble(ps.id, name: "b").subject
      expect(nx.nics_to_rekey.all).to eq([])
      nic1.update(state: "creating")
      expect(nx.nics_to_rekey.map(&:name)).to eq(["a"])
      nic2.update(state: "active")
      expect(nx.nics_to_rekey.map(&:name).sort).to eq(["a", "b"])
    end
  end

  describe "#start" do
    it "hops to wait if location is not aws" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#before_run" do
    it "hops to destroy when destroy is set" do
      nx.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy while v2 claims are held" do
      nx.incr_destroy
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_coordinator_id: ps.id)
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#wait" do
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: ps.id))
    }

    it "hops to refresh_keys if when_refresh_keys_set?" do
      nx.incr_refresh_keys
      expect { nx.wait }.to hop("refresh_keys")
      expect(ps.reload.state).to eq("refreshing_keys")
    end

    it "increments refresh_keys if it passed more than a day" do
      ps.update(last_rekey_at: Time.now - 60 * 60 * 24 - 1)
      expect { nx.wait }.to nap(10 * 60)
      expect(Semaphore.where(strand_id: ps.id, name: "refresh_keys").count).to eq(1)
    end

    it "triggers update_firewall_rules if when_update_firewall_rules_set?" do
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
      vm = Prog::Vm::Nexus.assemble("pub key", prj.id, name: "test-vm", private_subnet_id: ps.id, nic_id: nic.id).subject
      expect(vm.update_firewall_rules_set?).to be false

      nx.incr_update_firewall_rules
      expect { nx.wait }.to nap(10 * 60)
      expect(vm.reload.update_firewall_rules_set?).to be true
    end

    it "naps if nothing to do" do
      expect { nx.wait }.to nap(10 * 60)
    end

    context "when rekey_protocol is v2" do
      before { ps.update(rekey_protocol: 2) }

      it "fails if v2 claims are held" do
        Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_coordinator_id: ps.id)
        expect { nx.wait }.to raise_error(RuntimeError, "BUG: locks held while in wait (NoOrphanedLocks)")
      end

      it "forwards refresh_keys to the connected leader when not the leader" do
        Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: leader_ps.id)
        nx
        ps.connect_subnet(leader_ps)
        Semaphore.where(strand_id: [ps.id, leader_ps.id], name: "refresh_keys").destroy
        nx.incr_refresh_keys
        expect { nx.wait }.to nap(0)
        expect(ps.refresh_keys_set?).to be false
        expect(leader_ps.refresh_keys_set?).to be true
      end

      it "consumes refresh_keys and hops to refresh_keys as the leader" do
        nx.incr_refresh_keys
        expect { nx.wait }.to hop("refresh_keys")
        expect(ps.refresh_keys_set?).to be false
      end

      it "triggers update_firewall_rules if when_update_firewall_rules_set?" do
        nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
        vm = Prog::Vm::Nexus.assemble("pub key", prj.id, name: "test-vm", private_subnet_id: ps.id, nic_id: nic.id).subject
        nx.incr_update_firewall_rules
        expect { nx.wait }.to nap(10 * 60)
        expect(vm.reload.update_firewall_rules_set?).to be true
      end

      it "increments refresh_keys as the leader if it passed more than a day" do
        ps.update(last_rekey_at: Time.now - 60 * 60 * 24 - 1)
        expect { nx.wait }.to nap(10 * 60)
        expect(ps.refresh_keys_set?).to be true
      end

      it "does not enqueue refresh_keys for itself when not the leader" do
        Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: leader_ps.id)
        nx
        ps.connect_subnet(leader_ps)
        Semaphore.where(strand_id: [ps.id, leader_ps.id], name: "refresh_keys").destroy
        ps.update(last_rekey_at: Time.now - 60 * 60 * 24 - 1)
        expect { nx.wait }.to nap(10 * 60)
        expect(ps.refresh_keys_set?).to be false
      end

      it "naps if nothing to do" do
        expect { nx.wait }.to nap(10 * 60)
      end
    end
  end

  describe "#refresh_keys" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").update(label: "wait").subject
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "refresh_keys", id: ps.id))
    }

    it "refreshes keys and hops to wait_refresh_keys" do
      expect(nic.start_rekey_set?).to be false
      expect(nic.lock_set?).to be false
      nic.update(state: "active")
      expect(SecureRandom).to receive(:bytes).with(36).and_return("\x0a\x0b\x0c\x0d" * 9).ordered
      expect(SecureRandom).to receive(:bytes).with(4).and_return("\xe3\xaf\x3a\x04").ordered
      expect(SecureRandom).to receive(:bytes).with(4).and_return("\xe3\xaf\x3a\x04").ordered
      expect(SecureRandom).to receive(:random_number).with(1...100000).and_return(86879).ordered
      expect { nx.refresh_keys }.to hop("wait_inbound_setup")
      nic.refresh
      expect(nic.encryption_key).to eq "0x" + "0a0b0c0d" * 9
      expect(nic.rekey_payload).to eq("spi4" => "0xe3af3a04", "spi6" => "0xe3af3a04", "reqid" => 86879)
      expect(nic.start_rekey_set?).to be true
      expect(nic.lock_set?).to be true
    end

    it "naps if the nics are locked" do
      nic.incr_lock
      nic.update(state: "active")
      expect { nx.refresh_keys }.to nap(10)
    end

    it "naps if a v2 coordinator holds a claim on a nic" do
      nic.update(state: "active", rekey_coordinator_id: ps2.id)
      expect { nx.refresh_keys }.to nap(10)
    end

    context "when rekey_protocol is v2" do
      before { ps.update(rekey_protocol: 2) }

      it "fails if claims are held at idle" do
        nic.update(rekey_coordinator_id: ps.id)
        expect { nx.refresh_keys }.to raise_error(RuntimeError, "BUG: locks held at idle")
      end

      it "re-enqueues and hops to wait if no longer the leader" do
        Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: leader_ps.id)
        nx
        ps.connect_subnet(leader_ps)
        Semaphore.where(strand_id: [ps.id, leader_ps.id], name: "refresh_keys").destroy
        expect { nx.refresh_keys }.to hop("wait")
        expect(ps.refresh_keys_set?).to be true
      end

      it "hops to wait without re-enqueueing if there are no nics to rekey" do
        expect { nx.refresh_keys }.to hop("wait")
        expect(ps.refresh_keys_set?).to be false
      end

      it "naps if another coordinator holds a claim" do
        nic.update(state: "active", rekey_coordinator_id: ps2.id)
        expect { nx.refresh_keys }.to nap(10)
        expect(ps.refresh_keys_set?).to be false
      end

      it "naps on v1 lock residue" do
        nic.incr_lock
        nic.update(state: "active")
        expect { nx.refresh_keys }.to nap(10)
        expect(ps.refresh_keys_set?).to be false
      end

      it "fails if a nic to claim is not idle" do
        nic.update(state: "active", rekey_phase: "inbound")
        expect { nx.refresh_keys }.to raise_error(RuntimeError, "BUG: freshly locked NICs should all be idle: [\"#{nic.id}=inbound\"]")
      end

      it "claims the nics, refreshes keys and hops to wait_inbound_setup" do
        nic.update(state: "active")
        expect { nx.refresh_keys }.to hop("wait_inbound_setup")
        nic.reload
        expect(nic.rekey_coordinator_id).to eq ps.id
        expect(nic.encryption_key).to be_a String
        expect(nic.rekey_payload.keys).to eq ["spi4", "spi6", "reqid"]
        expect(nic.start_rekey_set?).to be true
        expect(ps.reload.state).to eq "refreshing_keys"
      end
    end
  end

  describe "#wait_inbound_setup" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_inbound_setup", id: ps.id, stack: [{"locked_nics" => [nic.id]}]))
    }

    it "naps 5 if state creation is ongoing" do
      nic
      expect { nx.wait_inbound_setup }.to nap(5)
    end

    it "hops to wait_outbound_setup if state creation is done" do
      nic.strand.update(label: "wait_rekey_outbound_trigger")
      expect(nic.trigger_outbound_update_set?).to be false
      expect { nx.wait_inbound_setup }.to hop("wait_outbound_setup")
      nic.refresh
      expect(nic.trigger_outbound_update_set?).to be true
    end

    context "when the pass is v2" do
      let(:nic) {
        Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {}, rekey_coordinator_id: ps.id)
      }
      let(:nx) {
        described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_inbound_setup", id: ps.id))
      }

      it "aborts to wait if all claimed nics are gone" do
        ps.update(state: "refreshing_keys")
        expect { nx.wait_inbound_setup }.to hop("wait")
        expect(ps.reload.state).to eq "waiting"
      end

      it "fails if a nic is beyond the inbound phase" do
        nic.update(rekey_phase: "outbound")
        expect { nx.wait_inbound_setup }.to raise_error(RuntimeError, "BUG: phase monotonicity at phase_inbound: [\"#{nic.id}=outbound\"]")
      end

      it "triggers outbound setup once all nics are inbound" do
        nic.update(rekey_phase: "inbound")
        expect { nx.wait_inbound_setup }.to hop("wait_outbound_setup")
        expect(nic.reload.trigger_outbound_update_set?).to be true
      end

      it "consumes nic_phase_done and naps while nics are still idle" do
        nic
        nx.incr_nic_phase_done
        expect { nx.wait_inbound_setup }.to nap(5)
          .and change { Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count }.from(1).to(0)
      end
    end
  end

  describe "#wait_outbound_setup" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_outbound_setup", id: ps.id, stack: [{"locked_nics" => [nic.id]}]))
    }

    it "donates if policy update is ongoing" do
      nic
      expect { nx.wait_outbound_setup }.to nap(5)
    end

    it "hops to wait_old_state_drop if policy update is done" do
      nic.strand.update(label: "wait_rekey_old_state_drop_trigger")
      expect(nic.old_state_drop_trigger_set?).to be false
      expect { nx.wait_outbound_setup }.to hop("wait_old_state_drop")
      nic.refresh
      expect(nic.old_state_drop_trigger_set?).to be true
    end

    context "when the pass is v2" do
      let(:nic) {
        Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {}, rekey_coordinator_id: ps.id)
      }
      let(:nx) {
        described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_outbound_setup", id: ps.id))
      }

      it "fails if a nic is outside the outbound transition" do
        nic.update(rekey_phase: "idle")
        expect { nx.wait_outbound_setup }.to raise_error(RuntimeError, "BUG: phase monotonicity at phase_outbound: [\"#{nic.id}=idle\"]")
      end

      it "triggers old state drop once all nics are outbound" do
        nic.update(rekey_phase: "outbound")
        expect { nx.wait_outbound_setup }.to hop("wait_old_state_drop")
        expect(nic.reload.old_state_drop_trigger_set?).to be true
      end

      it "consumes nic_phase_done and naps while nics are still inbound" do
        nic.update(rekey_phase: "inbound")
        nx.incr_nic_phase_done
        expect { nx.wait_outbound_setup }.to nap(5)
          .and change { Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count }.from(1).to(0)
      end
    end
  end

  describe "#wait_old_state_drop" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_old_state_drop", id: ps.id, stack: [{"locked_nics" => [nic.id]}]))
    }

    it "donates if policy update is ongoing" do
      nic
      expect { nx.wait_old_state_drop }.to nap(5)
    end

    it "hops to wait if all is done" do
      nic.strand.update(label: "wait")
      nic.update(rekey_coordinator_id: ps.id, rekey_phase: "old_drop")
      ps.update(last_rekey_at: Time.now - 100)
      expect { nx.wait_old_state_drop }.to hop("wait")
      ps.refresh
      expect(ps.state).to eq "waiting"
      expect(ps.last_rekey_at > Time.now - 10).to be true
      nic.refresh
      expect(nic.encryption_key).to be_nil
      expect(nic.rekey_payload).to be_nil
      expect(nic.rekey_coordinator_id).to be_nil
      expect(nic.rekey_phase).to eq "idle"
      expect(nic.lock_set?).to be false
    end

    context "when the pass is v2" do
      let(:nic) {
        Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {}, rekey_coordinator_id: ps.id)
      }
      let(:nx) {
        described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_old_state_drop", id: ps.id))
      }

      it "fails if a nic is outside the old_drop transition" do
        nic.update(rekey_phase: "inbound")
        expect { nx.wait_old_state_drop }.to raise_error(RuntimeError, "BUG: phase monotonicity at phase_old_drop: [\"#{nic.id}=inbound\"]")
      end

      it "stamps last_rekey_at on every member subnet, releases claims and hops to wait" do
        nic.update(rekey_phase: "old_drop")
        nic2 = Prog::Vnet::NicNexus.assemble(ps2.id, name: "b").subject.update(rekey_payload: {}, rekey_coordinator_id: ps.id, rekey_phase: "old_drop")
        ps.update(state: "refreshing_keys", last_rekey_at: Time.now - 100)
        ps2.update(last_rekey_at: Time.now - 100)
        expect { nx.wait_old_state_drop }.to hop("wait")
        ps.refresh
        expect(ps.state).to eq "waiting"
        expect(ps.last_rekey_at > Time.now - 10).to be true
        expect(ps2.reload.last_rekey_at > Time.now - 10).to be true
        [nic, nic2].each do |n|
          n.reload
          expect(n.encryption_key).to be_nil
          expect(n.rekey_payload).to be_nil
          expect(n.rekey_coordinator_id).to be_nil
          expect(n.rekey_phase).to eq "idle"
        end
      end

      it "consumes nic_phase_done and naps while nics are still outbound" do
        nic.update(rekey_phase: "outbound")
        nx.incr_nic_phase_done
        expect { nx.wait_old_state_drop }.to nap(5)
          .and change { Semaphore.where(strand_id: ps.id, name: "nic_phase_done").count }.from(1).to(0)
      end
    end
  end

  describe "#destroy" do
    let(:vm) {
      vm = create_vm
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "start")
      vm
    }

    let(:nic) {
      n = Nic.create(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic",
        state: "active")
      Strand.create_with_id(n, prog: "Vnet::NicNexus", label: "wait")
      n
    }

    it "fails if v2 claims are held" do
      nic.update(rekey_coordinator_id: ps.id)
      expect { nx.destroy }.to raise_error(RuntimeError, "BUG: locks held at destroy")
    end

    it "extends deadline if a vm prevents destroy" do
      nic.update(vm_id: vm.id)
      vm.incr_prevent_destroy

      expect { nx.destroy }.to nap(5)
      expect(nx.strand.stack.first["deadline_target"]).to be_nil
      expect(Time.parse(nx.strand.stack.first["deadline_at"])).to be_within(5).of(Time.now + 10 * 60)
    end

    it "fails if there are active resources" do
      nic.update(vm_id: vm.id)
      expect(Clog).to receive(:emit).with("Cannot destroy subnet with active nics, first clean up the attached resources", instance_of(PrivateSubnet)).and_call_original

      expect { nx.destroy }.to nap(5)
    end

    it "increments the destroy semaphore of nics" do
      nic
      expect(nx).to receive(:rand).with(5..10).and_return(6)
      expect { nx.destroy }.to nap(6)
      expect(nic.reload.destroy_set?).to be true
    end

    it "deletes and pops if nics are destroyed" do
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "disconnects all subnets" do
      prj = Project.create(name: "test-project")
      ps1 = PrivateSubnet.create(name: "ps1", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
      ps2 = PrivateSubnet.create(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
      Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "destroy", id: ps1.id)
      ps1.connect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id)).to eq [ps1.id]

      nx1 = described_class.new(ps1.strand)
      expect { nx1.destroy }.to exit({"msg" => "subnet destroyed"})
      expect(ps2.reload.connected_subnets).to be_empty
    end
  end
end
