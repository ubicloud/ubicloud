# frozen_string_literal: true

RSpec.describe Prog::Vnet::SubnetNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:prj) { Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) } }
  let(:ps) {
    PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting").tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
  }

  before do
    nx.instance_variable_set(:@private_subnet, ps)
  end

  describe ".assemble" do
    it "fails if project doesn't exist" do
      expect {
        described_class.assemble(nil)
      }.to raise_error RuntimeError, "No existing project"
    end

    it "uses ipv6_addr if passed and creates entities" do
      ps = instance_double(PrivateSubnet)
      expect(ps).to receive(:associate_with_project).with(prj).and_return(true)
      expect(PrivateSubnet).to receive(:create).with(
        name: "default-ps",
        location: "hetzner-hel1",
        net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "10.0.0.0/26",
        state: "waiting"
      ).and_return(ps)
      expect(described_class).to receive(:random_private_ipv4).and_return("10.0.0.0/26")
      expect(Strand).to receive(:create).with(prog: "Vnet::SubnetNexus", label: "wait").and_yield(Strand.new).and_return(Strand.new)
      described_class.assemble(
        prj.id,
        name: "default-ps",
        location: "hetzner-hel1",
        ipv6_range: "fd10:9b0b:6b4b:8fbb::/64"
      )
    end

    it "uses ipv4_addr if passed and creates entities" do
      ps = instance_double(PrivateSubnet)
      expect(ps).to receive(:associate_with_project).with(prj).and_return(true)
      expect(PrivateSubnet).to receive(:create).with(
        name: "default-ps",
        location: "hetzner-hel1",
        net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "10.0.0.0/26",
        state: "waiting"
      ).and_return(ps)
      expect(described_class).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/64")
      expect(Strand).to receive(:create).with(prog: "Vnet::SubnetNexus", label: "wait").and_yield(Strand.new).and_return(Strand.new)
      described_class.assemble(
        prj.id,
        name: "default-ps",
        location: "hetzner-hel1",
        ipv4_range: "10.0.0.0/26"
      )
    end
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

  describe "#wait" do
    it "hops to destroy if when_destroy_set?" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect {
        nx.wait
      }.to hop("destroy")
    end

    it "hops to refresh_mesh if when_refresh_mesh_set?" do
      expect(nx).to receive(:when_refresh_mesh_set?).and_yield
      expect(ps).to receive(:update).with(state: "refreshing_mesh").and_return(true)
      expect {
        nx.wait
      }.to hop("refresh_mesh")
    end

    it "hops to refresh_keys if when_refresh_keys_set?" do
      expect(nx).to receive(:when_refresh_keys_set?).and_yield
      expect(ps).to receive(:update).with(state: "refreshing_keys").and_return(true)
      expect {
        nx.wait
      }.to hop("refresh_keys")
    end

    it "increments refresh_keys if it passed more than a day" do
      expect(ps).to receive(:last_rekey_at).and_return(Time.now - 60 * 60 * 24 - 1)
      expect(ps).to receive(:incr_refresh_keys).and_return(true)
      expect { nx.wait }.to nap(30)
    end

    it "naps if nothing to do" do
      expect {
        nx.wait
      }.to nap(30)
    end
  end

  describe "#refresh_keys" do
    let(:nic) {
      instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133", rekey_payload: {})
    }

    it "refreshes keys and hops to wait_refresh_keys" do
      expect(ps).to receive(:nics).and_return([nic]).twice
      expect(nx).to receive(:gen_spi).and_return("0xe3af3a04").twice
      expect(nx).to receive(:gen_reqid).and_return(86879)
      expect(nx).to receive(:gen_encryption_key).and_return("0x0a0b0c0d0e0f10111213141516171819")
      expect(nic).to receive(:update).with(encryption_key: "0x0a0b0c0d0e0f10111213141516171819", rekey_payload:
        {
          spi4: "0xe3af3a04",
          spi6: "0xe3af3a04",
          reqid: 86879
        }).and_return(true)
      expect(nic).to receive(:incr_start_rekey).and_return(true)
      expect {
        nx.refresh_keys
      }.to hop("wait_inbound_setup")
    end
  end

  describe "#wait_inbound_setup" do
    let(:nic) {
      st = instance_double(Strand, label: "start")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "donates if state creation is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_inbound_setup }.to nap(0)
    end

    it "hops to wait_policy_updated if state creation is done" do
      expect(nic.strand).to receive(:label).and_return("wait_rekey_outbound_trigger")
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_trigger_outbound_update).and_return(true)
      expect {
        nx.wait_inbound_setup
      }.to hop("wait_outbound_setup")
    end
  end

  describe "#wait_outbound_setup" do
    let(:nic) {
      st = instance_double(Strand, label: "wait_rekey_outbound")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "donates if policy update is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_outbound_setup }.to nap(0)
    end

    it "hops to wait_state_dropped if policy update is done" do
      expect(nic.strand).to receive(:label).and_return("wait_rekey_old_state_drop_trigger")
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_old_state_drop_trigger).and_return(true)
      expect {
        nx.wait_outbound_setup
      }.to hop("wait_old_state_drop")
    end
  end

  describe "#wait_old_state_drop" do
    let(:nic) {
      st = instance_double(Strand, label: "wait_rekey_old_state_drop")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "donates if policy update is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_old_state_drop }.to nap(0)
    end

    it "hops to wait if all is done" do
      t = Time.now
      expect(Time).to receive(:now).and_return(t)
      expect(nic.strand).to receive(:label).and_return("wait")
      expect(ps).to receive(:update).with(state: "waiting", last_rekey_at: t).and_return(true)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:rekey_payload).and_return({})
      expect(nic).to receive(:update).with(encryption_key: nil, rekey_payload: nil).and_return(true)
      expect(nx).to receive(:decr_refresh_keys).and_return(true)
      expect {
        nx.wait_old_state_drop
      }.to hop("wait")
    end

    it "doesn't decrement refresh_keys if there are missed nics" do
      t = Time.now
      expect(Time).to receive(:now).and_return(t)
      expect(nic.strand).to receive(:label).and_return("wait")
      expect(ps).to receive(:update).with(state: "waiting", last_rekey_at: t).and_return(true)
      expect(nx).to receive(:rekeying_nics).and_return([nic]).at_least(:once)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:rekey_payload).and_return(nil)
      expect(nic).to receive(:update).with(encryption_key: nil, rekey_payload: nil).and_return(true)
      expect(nx).not_to receive(:decr_refresh_keys)
      expect {
        nx.wait_old_state_drop
      }.to hop("wait")
    end
  end

  describe "#refresh_mesh" do
    let(:nic) {
      instance_double(Nic)
    }

    it "refreshes mesh and hops to wait_refresh_mesh" do
      expect(ps).to receive(:nics).and_return([nic])
      expect(nic).to receive(:incr_refresh_mesh).and_return(true)
      expect(SecureRandom).to receive(:bytes).with(36).and_return("cr\x99tnpn\x8F\x89\xCBma2\x01\x1C\xF9\xA3\xCD\xF7\xC0\xEF@w\xA9\x85\x7F\x1E\xB3T\xE3~\xB7\xFD7l\x91")
      expect(nic).to receive(:update).with(encryption_key: "0x637299746e706e8f89cb6d6132011cf9a3cdf7c0ef4077a9857f1eb354e37eb7fd376c91").and_return(true)
      expect {
        nx.refresh_mesh
      }.to hop("wait_refresh_mesh")
    end
  end

  describe "#wait_refresh_mesh" do
    let(:nic) {
      instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133")
    }
    let(:ss) { instance_double(SemSnap, set?: true) }

    it "naps if there is a nic to refresh" do
      expect(SemSnap).to receive(:new).with(nic.id).and_return(ss)
      expect(ps).to receive(:nics).and_return([nic])
      expect {
        nx.wait_refresh_mesh
      }.to nap(1)
    end

    it "hops back to wait if nics are done" do
      expect(ss).to receive(:set?).and_return(false)
      expect(SemSnap).to receive(:new).with(nic.id).and_return(ss)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(ps).to receive(:update).with(state: "waiting").and_return(true)
      expect(nic).to receive(:update).with(encryption_key: nil).and_return(true)
      expect(nx).to receive(:decr_refresh_mesh).and_return(true)
      expect {
        nx.wait_refresh_mesh
      }.to hop("wait")
    end
  end

  describe ".random_private_ipv4" do
    it "returns a random private ipv4 range" do
      expect(described_class.random_private_ipv4("hetzner-hel1")).to be_a NetAddr::IPv4Net
    end

    it "finds a new subnet if the one it found is taken" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/12").twice
      expect(SecureRandom).to receive(:random_number).with(16383).and_return(1, 2)
      expect(PrivateSubnet).to receive(:where).with(net4: "172.16.0.128/26", location: "hetzner-hel1").and_return([true])
      expect(PrivateSubnet).to receive(:where).with(net4: "172.16.0.192/26", location: "hetzner-hel1").and_return([])
      expect(described_class.random_private_ipv4("hetzner-hel1").to_s).to eq("172.16.0.192/26")
    end
  end

  describe ".random_private_ipv6" do
    it "returns a random private ipv6 range" do
      expect(described_class.random_private_ipv6("hetzner-hel1")).to be_a NetAddr::IPv6Net
    end

    it "finds a new subnet if the one it found is taken" do
      expect(SecureRandom).to receive(:bytes).with(7).and_return("a" * 7, "b" * 7)
      expect(PrivateSubnet).to receive(:where).with(net6: "fd61:6161:6161:6161::/64", location: "hetzner-hel1").and_return([true])
      expect(PrivateSubnet).to receive(:where).with(net6: "fd62:6262:6262:6262::/64", location: "hetzner-hel1").and_return([])
      expect(described_class.random_private_ipv6("hetzner-hel1").to_s).to eq("fd62:6262:6262:6262::/64")
    end
  end

  describe "#destroy" do
    let(:nic) {
      instance_double(Nic, vm_id: nil)
    }

    it "fails if there are active resources" do
      expect(ps).to receive(:nics).and_return([nic])
      expect(nic).to receive(:vm_id).and_return("vm-id")
      expect { nx.destroy }.to raise_error RuntimeError, "Cannot destroy subnet with active nics, first clean up the attached resources"
    end

    it "increments the destroy semaphore of nics" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_destroy).and_return(true)
      expect { nx.destroy }.to nap(1)
    end

    it "deletes and pops if nics are destroyed" do
      expect(ps).to receive(:destroy).and_return(true)
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:projects).and_return([prj]).at_least(:once)
      expect(ps).to receive(:dissociate_with_project).with(prj).and_return(true)
      expect(nx).to receive(:pop).with("subnet destroyed").and_return(true)
      nx.destroy
    end
  end
end
