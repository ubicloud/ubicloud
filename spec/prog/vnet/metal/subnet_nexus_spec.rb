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
      expect(nx.nics_to_rekey).to eq([])
      nic1.update(state: "creating")
      expect(nx.nics_to_rekey.map(&:name)).to eq(["a"])
      nic2.update(state: "active")
      expect(nx.nics_to_rekey.map(&:name).sort).to eq(["a", "b"])
    end
  end

  describe "#before_run" do
    it "defers destroy while locked nics exist" do
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject
      nic.update(state: "active")
      strand = Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_inbound_setup", id: ps.id)
      ps.incr_destroy
      nx_mid_rekey = described_class.new(strand)
      nx_mid_rekey.update_stack_locked_nics([nic.id])

      nx_mid_rekey.before_run
      expect(nx_mid_rekey.strand.label).to eq("wait_inbound_setup")
    end

    it "allows destroy when no locked nics exist" do
      strand = Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: ps.id)
      ps.incr_destroy
      nx_in_wait = described_class.new(strand)

      expect { nx_in_wait.before_run }.to hop("destroy")
    end
  end

  describe "#start" do
    it "hops to wait if location is not aws" do
      expect { nx.start }.to hop("wait")
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

    it "forwards refresh_keys to connected leader when not the leader" do
      nx # ensure ps has a strand
      Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: ps2.id)
      ps.connect_subnet(ps2)

      leader_id = [ps.id, ps2.id].min
      non_leader = (leader_id == ps.id) ? ps2 : ps
      leader = (leader_id == ps.id) ? ps : ps2

      non_leader.incr_refresh_keys
      non_leader_nx = described_class.new(Strand[non_leader.id])
      expect { non_leader_nx.wait }.to nap(0)
      expect(Semaphore.where(strand_id: leader.id, name: "refresh_keys").count).to be >= 1
    end

    it "does not check periodic rekey when not the connected leader" do
      ps.update(last_rekey_at: Time.now - 60 * 60 * 24 - 1)
      nx2 = described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: ps2.id))
      nx_leader, nx_non_leader = [nx, nx2].sort_by { it.private_subnet.id }
      expect(nx_non_leader).to receive(:connected_leader?).and_return(false)
      expect { nx_non_leader.wait }.to nap(10 * 60)
      expect(Semaphore.where(strand_id: nx_leader.private_subnet.id, name: "refresh_keys").count).to eq(0)
    end

    it "naps if nothing to do" do
      expect { nx.wait }.to nap(10 * 60)
    end
  end

  describe "#refresh_keys" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").update(label: "wait").subject
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "refresh_keys", id: ps.id))
    }

    it "hops to wait if not the connected leader" do
      expect(nx).to receive(:connected_leader?).and_return(false)
      expect(Clog).to receive(:emit)
      expect { nx.refresh_keys }.to hop("wait")
      expect(Semaphore.where(strand_id: nx.private_subnet.id, name: "refresh_keys").count).to eq(1)
    end

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

    it "naps if advisory lock cannot be acquired" do
      nic.update(state: "active")
      expect(nx).to receive(:connected_leader?).and_return(true)
      expect(nx).to receive(:try_advisory_lock).and_return(false)
      expect { nx.refresh_keys }.to nap(10)
    end
  end

  describe "#wait_inbound_setup" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      nx = described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_inbound_setup", id: ps.id))
      nx.update_stack_locked_nics([nic.id])
      nx
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
  end

  describe "#wait_outbound_setup" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      nx = described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_outbound_setup", id: ps.id))
      nx.update_stack_locked_nics([nic.id])
      nx
    }

    it "donates if policy update is ongoing" do
      nic
      expect { nx.wait_outbound_setup }.to nap(5)
    end

    it "hops to wait_state_dropped if policy update is done" do
      nic.strand.update(label: "wait_rekey_old_state_drop_trigger")
      expect(nic.old_state_drop_trigger_set?).to be false
      expect { nx.wait_outbound_setup }.to hop("wait_old_state_drop")
      nic.refresh
      expect(nic.old_state_drop_trigger_set?).to be true
    end
  end

  describe "#wait_old_state_drop" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      nx = described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_old_state_drop", id: ps.id))
      nx.update_stack_locked_nics([nic.id])
      nx
    }

    it "donates if policy update is ongoing" do
      nic
      expect { nx.wait_old_state_drop }.to nap(5)
    end

    it "hops to wait if all is done" do
      nic.strand.update(label: "wait")
      ps.update(last_rekey_at: Time.now - 100)
      expect { nx.wait_old_state_drop }.to hop("wait")
      ps.refresh
      expect(ps.state).to eq "waiting"
      expect(ps.last_rekey_at > Time.now - 10).to be true
      nic.refresh
      expect(nic.encryption_key).to be_nil
      expect(nic.rekey_payload).to be_nil
      expect(nic.lock_set?).to be false
    end

    it "updates last_rekey_at on all connected subnets" do
      Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait", id: ps2.id)
      ps.connect_subnet(ps2)
      nic2 = Prog::Vnet::NicNexus.assemble(ps2.id, name: "b").subject.update(rekey_payload: {})

      nx_with_both = described_class.new(Strand.create(prog: "Vnet::Metal::SubnetNexus", label: "wait_old_state_drop", id: ps.id))
      nx_with_both.update_stack_locked_nics([nic.id, nic2.id])

      nic.strand.update(label: "wait")
      nic2.strand.update(label: "wait")
      ps.update(last_rekey_at: Time.now - 100)
      ps2.update(last_rekey_at: Time.now - 100)

      expect { nx_with_both.wait_old_state_drop }.to hop("wait")
      expect(ps.reload.last_rekey_at > Time.now - 10).to be true
      expect(ps2.reload.last_rekey_at > Time.now - 10).to be true
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

    it "extends deadline if a vm prevents destroy" do
      nic.update(vm_id: vm.id)
      vm.incr_prevent_destroy

      expect { nx.destroy }.to nap(5)
      expect(nx.strand.stack.first["deadline_target"]).to be_nil
      expect(nx.strand.stack.first["deadline_at"]).to be_within(5).of(Time.now + 10 * 60)
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
