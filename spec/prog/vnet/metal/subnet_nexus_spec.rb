# frozen_string_literal: true

RSpec.describe Prog::Vnet::Metal::SubnetNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:prj) { Project.create(name: "default") }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
  }

  let(:ps2) {
    PrivateSubnet.create(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fcc::/64",
      net4: "1.1.1.128/26", state: "waiting", project_id: prj.id)
  }

  before do
    nx.instance_variable_set(:@private_subnet, ps)
  end

  describe ".gen_spi" do
    it "generates a random spi" do
      expect(SecureRandom).to receive(:bytes).with(4).and_return("e3af3a04")
      expect(nx.gen_spi).to eq("0x6533616633613034")
    end
  end

  describe ".gen_reqid" do
    it "generates a random reqid" do
      expect(SecureRandom).to receive(:random_number).with(100000).and_return(10)
      expect(nx.gen_reqid).to eq(11)
    end
  end

  describe ".gen_encryption_key" do
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
      nic1.strand.update(label: "wait")
      expect(nx.nics_to_rekey.map(&:name)).to eq(["a"])
      nic2.strand.update(label: "wait_setup")
      expect(nx.nics_to_rekey.map(&:name).sort).to eq(["a", "b"])
    end
  end

  describe "#before_run" do
    it "hops to destroy if when_destroy_set?" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if when_destroy_set? from wait_fw_rules" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_fw_rules").at_least(:once)
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if strand is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "hops to wait if location is not aws" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to refresh_keys if when_refresh_keys_set?" do
      expect(nx).to receive(:when_refresh_keys_set?).and_yield
      expect(ps).to receive(:update).with(state: "refreshing_keys").and_return(true)
      expect { nx.wait }.to hop("refresh_keys")
    end

    it "hops to add_new_nic if when_add_new_nic_set?" do
      expect(nx).to receive(:when_add_new_nic_set?).and_yield
      expect(ps).to receive(:update).with(state: "adding_new_nic").and_return(true)
      expect { nx.wait }.to hop("add_new_nic")
    end

    it "increments refresh_keys if it passed more than a day" do
      expect(ps).to receive(:last_rekey_at).and_return(Time.now - 60 * 60 * 24 - 1)
      expect(ps).to receive(:incr_refresh_keys).and_return(true)
      expect { nx.wait }.to nap(10 * 60)
    end

    it "triggers update_firewall_rules if when_update_firewall_rules_set?" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect(ps).to receive(:vms).and_return([instance_double(Vm, id: "vm1")]).at_least(:once)
      expect(ps.vms.first).to receive(:incr_update_firewall_rules).and_return(true)
      expect(nx).to receive(:decr_update_firewall_rules).and_return(true)
      expect { nx.wait }.to nap(10 * 60)
    end

    it "naps if nothing to do" do
      expect { nx.wait }.to nap(10 * 60)
    end
  end

  describe "#add_new_nic" do
    it "adds new nics and creates tunnels" do
      st = instance_double(Strand, label: "wait_setup")
      nic_to_add = instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133", rekey_payload: {}, strand: st, lock_set?: false)
      st = instance_double(Strand, label: "wait")
      added_nic = instance_double(Nic, id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", rekey_payload: {}, strand: st, lock_set?: false)
      nics_to_rekey = [added_nic, nic_to_add]
      expect(nx).to receive(:decr_add_new_nic)
      expect(nic_to_add).to receive(:incr_lock)
      expect(added_nic).to receive(:incr_lock)
      expect(nic_to_add).to receive(:incr_start_rekey)
      expect(added_nic).to receive(:incr_start_rekey)
      expect(nx).to receive(:nics_to_rekey).and_return(nics_to_rekey)
      expect(nx).to receive(:gen_spi).and_return("0xe3af3a04").at_least(:once)
      expect(nx).to receive(:gen_reqid).and_return(86879).at_least(:once)
      expect(nx).to receive(:gen_encryption_key).and_return("0x0a0b0c0d0e0f10111213141516171819").at_least(:once)
      expect(nx.private_subnet).to receive(:create_tunnels).and_return(true).at_least(:once)
      expect(added_nic).to receive(:update).with(encryption_key: "0x0a0b0c0d0e0f10111213141516171819", rekey_payload:
        {
          spi4: "0xe3af3a04",
          spi6: "0xe3af3a04",
          reqid: 86879
        }).and_return(true)
      expect(nic_to_add).to receive(:update).with(encryption_key: "0x0a0b0c0d0e0f10111213141516171819", rekey_payload:
        {
          spi4: "0xe3af3a04",
          spi6: "0xe3af3a04",
          reqid: 86879
        }).and_return(true)
      expect { nx.add_new_nic }.to hop("wait_inbound_setup")
    end

    it "naps if the nics are locked" do
      st = instance_double(Strand, label: "wait_setup")
      nic_to_add = instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133", rekey_payload: {}, strand: st, lock_set?: false)
      st = instance_double(Strand, label: "wait")
      added_nic = instance_double(Nic, id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", rekey_payload: {}, strand: st, lock_set?: false)
      nics_to_rekey = [added_nic, nic_to_add]
      expect(added_nic).to receive(:lock_set?).and_return(true)
      expect(nx).to receive(:nics_to_rekey).and_return(nics_to_rekey)
      expect { nx.add_new_nic }.to nap(10)
    end
  end

  describe "#refresh_keys" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").update(label: "wait").subject
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::SubnetNexus", label: "refresh_keys", id: ps.id))
    }

    it "refreshes keys and hops to wait_refresh_keys" do
      expect(nx).to receive(:gen_spi).and_return("0xe3af3a04").at_least(:once)
      expect(nx).to receive(:gen_reqid).and_return(86879)
      expect(nx).to receive(:gen_encryption_key).and_return("0x0a0b0c0d0e0f10111213141516171819")
      expect(nic.start_rekey_set?).to be false
      expect(nic.lock_set?).to be false
      expect { nx.refresh_keys }.to hop("wait_inbound_setup")
      nic.refresh
      expect(nic.encryption_key).to eq "0x0a0b0c0d0e0f10111213141516171819"
      expect(nic.rekey_payload).to eq("spi4" => "0xe3af3a04", "spi6" => "0xe3af3a04", "reqid" => 86879)
      expect(nic.start_rekey_set?).to be true
      expect(nic.lock_set?).to be true
    end

    it "naps if the nics are locked" do
      nic.incr_lock
      expect { nx.refresh_keys }.to nap(10)
    end
  end

  describe "#wait_inbound_setup" do
    let(:nic) {
      Prog::Vnet::NicNexus.assemble(ps.id, name: "a").subject.update(rekey_payload: {})
    }
    let(:nx) {
      described_class.new(Strand.create(prog: "Vnet::SubnetNexus", label: "wait_inbound_setup", id: ps.id))
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
      described_class.new(Strand.create(prog: "Vnet::SubnetNexus", label: "wait_outbound_setup", id: ps.id))
    }

    it "naps if policy update is ongoing" do
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
      described_class.new(Strand.create(prog: "Vnet::SubnetNexus", label: "wait_old_state_drop", id: ps.id))
    }

    it "donates if policy update is ongoing" do
      nic
      expect { nx.wait_old_state_drop }.to nap(5)
    end

    it "hops to wait if all is done" do
      nic.strand.update(label: "wait")
      nic.incr_lock
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
  end

  describe "#destroy" do
    let(:nic) {
      instance_double(Nic, vm_id: nil)
    }

    it "extends deadline if a vm prevents destroy" do
      vm = Vm.new(family: "standard", cores: 1, name: "dummy-vm", location_id: Location::HETZNER_FSN1_ID).tap {
        it.id = "788525ed-d6f0-4937-a844-323d4fd91946"
      }
      expect(ps).to receive(:nics).and_return([nic]).twice
      expect(nic).to receive(:vm_id).and_return("vm-id")
      expect(nic).to receive(:vm).and_return(vm)
      expect(vm).to receive(:prevent_destroy_set?).and_return(true)
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60, allow_extension: true)

      expect { nx.destroy }.to nap(5)
    end

    it "fails if there are active resources" do
      expect(ps).to receive(:nics).and_return([nic]).twice
      expect(nic).to receive(:vm_id).and_return("vm-id")
      expect(nic).to receive(:vm).and_return(nil)
      expect(Clog).to receive(:emit).with("Cannot destroy subnet with active nics, first clean up the attached resources").and_call_original

      expect { nx.destroy }.to nap(5)
    end

    it "increments the destroy semaphore of nics" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_destroy).and_return(true)
      expect(nx).to receive(:rand).with(5..10).and_return(6)
      expect { nx.destroy }.to nap(6)
    end

    it "deletes and pops if nics are destroyed" do
      expect(ps).to receive(:destroy).and_return(true)
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "disconnects all subnets" do
      prj = Project.create(name: "test-project")
      ps1 = PrivateSubnet.create(name: "ps1", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
      ps2 = PrivateSubnet.create(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
      ps1.connect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id)).to eq [ps1.id]

      expect(nx).to receive(:private_subnet).and_return(ps1).at_least(:once)
      expect(ps1).to receive(:disconnect_subnet).with(ps2).and_call_original
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end
  end
end
