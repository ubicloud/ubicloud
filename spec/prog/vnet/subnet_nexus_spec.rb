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
      expect(described_class).to receive(:random_private_ipv4).and_return("10.0.0.0/26")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location: "hetzner-hel1",
        ipv6_range: "fd10:9b0b:6b4b:8fbb::/64"
      )

      expect(ps.subject.net6.to_s).to eq("fd10:9b0b:6b4b:8fbb::/64")
    end

    it "uses ipv4_addr if passed and creates entities" do
      expect(described_class).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/64")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location: "hetzner-hel1",
        ipv4_range: "10.0.0.0/26"
      )

      expect(ps.subject.net4.to_s).to eq("10.0.0.0/26")
    end

    it "uses firewall if provided" do
      fw = Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1").tap { _1.associate_with_project(prj) }
      ps = described_class.assemble(prj.id, firewall_id: fw.id)
      expect(ps.subject.firewalls.count).to eq(1)
      expect(ps.subject.firewalls.first).to eq(fw)
    end

    it "fails if provided firewall does not exist" do
      expect {
        described_class.assemble(prj.id, firewall_id: "550e8400-e29b-41d4-a716-446655440000")
      }.to raise_error RuntimeError, "Firewall with id 550e8400-e29b-41d4-a716-446655440000 and location hetzner-hel1 does not exist"
    end

    it "fails if firewall is not in the project" do
      fw = Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1")
      expect {
        described_class.assemble(prj.id, firewall_id: fw.id)
      }.to raise_error RuntimeError, "Firewall with id #{fw.id} and location hetzner-hel1 does not exist"
    end

    it "fails if both allow_only_ssh and firewall_id are specified" do
      fw = Firewall.create_with_id(name: "default-firewall", location: "hetzner-hel1").tap { _1.associate_with_project(prj) }
      expect {
        described_class.assemble(prj.id, firewall_id: fw.id, allow_only_ssh: true)
      }.to raise_error RuntimeError, "Cannot specify both allow_only_ssh and firewall_id"
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

  describe ".gen_encryption_key" do
    it "generates a random encryption key" do
      expect(SecureRandom).to receive(:bytes).with(36).and_return("e3af3a04")
      expect(nx.gen_encryption_key).to eq("0x6533616633613034")
    end
  end

  describe ".nics_to_rekey" do
    it "returns nics that need rekeying" do
      st_act = instance_double(Strand, label: "wait")
      st_wait = instance_double(Strand, label: "wait_setup")
      active_nic = instance_double(Nic, id: "n2", strand: st_act)
      to_add_nic = instance_double(Nic, id: "n1", strand: st_wait)
      expect(ps).to receive(:nics).and_return([active_nic, to_add_nic]).at_least(:once)
      expect(nx.nics_to_rekey.flatten.map(&:id).sort).to eq(["n1", "n2"])
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
      expect { nx.wait }.to nap(30)
    end

    it "triggers update_firewall_rules if when_update_firewall_rules_set?" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect(ps).to receive(:vms).and_return([instance_double(Vm, id: "vm1")]).at_least(:once)
      expect(ps.vms.first).to receive(:incr_update_firewall_rules).and_return(true)
      expect(nx).to receive(:decr_update_firewall_rules).and_return(true)
      expect { nx.wait }.to nap(30)
    end

    it "naps if nothing to do" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#add_new_nic" do
    let(:nic_to_add) {
      st = instance_double(Strand, label: "wait_setup")
      instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133", rekey_payload: {}, strand: st)
    }
    let(:added_nic) {
      st = instance_double(Strand, label: "wait")
      instance_double(Nic, id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", rekey_payload: {}, strand: st)
    }

    it "adds new nics and creates tunnels" do
      nics_to_rekey = [added_nic, nic_to_add]
      expect(nx).to receive(:decr_add_new_nic)
      expect(nic_to_add).to receive(:incr_start_rekey)
      expect(added_nic).to receive(:incr_start_rekey)
      expect(nx).to receive(:nics_to_rekey).and_return(nics_to_rekey)
      expect(nx).to receive(:gen_spi).and_return("0xe3af3a04").at_least(:once)
      expect(nx).to receive(:gen_reqid).and_return(86879).at_least(:once)
      expect(nx).to receive(:gen_encryption_key).and_return("0x0a0b0c0d0e0f10111213141516171819").at_least(:once)
      expect(nx).to receive(:create_tunnels).and_return(true).at_least(:once)
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
  end

  describe "#refresh_keys" do
    let(:nic) {
      st = instance_double(Strand, label: "wait")
      instance_double(Nic, id: "57afa8a7-2357-4012-9632-07fbe13a3133", rekey_payload: {}, strand: st)
    }

    it "refreshes keys and hops to wait_refresh_keys" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nx).to receive(:gen_spi).and_return("0xe3af3a04").at_least(:once)
      expect(nx).to receive(:gen_reqid).and_return(86879)
      expect(nx).to receive(:gen_encryption_key).and_return("0x0a0b0c0d0e0f10111213141516171819")
      expect(nic).to receive(:update).with(encryption_key: "0x0a0b0c0d0e0f10111213141516171819", rekey_payload:
        {
          spi4: "0xe3af3a04",
          spi6: "0xe3af3a04",
          reqid: 86879
        }).and_return(true)
      expect(nic).to receive(:incr_start_rekey).and_return(true)
      expect { nx.refresh_keys }.to hop("wait_inbound_setup")
    end
  end

  describe "#wait_inbound_setup" do
    let(:nic) {
      st = instance_double(Strand, label: "start")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "naps 5 if state creation is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect { nx.wait_inbound_setup }.to nap(5)
    end

    it "hops to wait_policy_updated if state creation is done" do
      expect(nic.strand).to receive(:label).and_return("wait_rekey_outbound_trigger")
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_trigger_outbound_update).and_return(true)
      expect { nx.wait_inbound_setup }.to hop("wait_outbound_setup")
    end
  end

  describe "#wait_outbound_setup" do
    let(:nic) {
      st = instance_double(Strand, label: "wait_rekey_outbound")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "donates if policy update is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)

      expect { nx.wait_outbound_setup }.to nap(5)
    end

    it "hops to wait_state_dropped if policy update is done" do
      expect(nic.strand).to receive(:label).and_return("wait_rekey_old_state_drop_trigger")
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_old_state_drop_trigger).and_return(true)
      expect { nx.wait_outbound_setup }.to hop("wait_old_state_drop")
    end
  end

  describe "#wait_old_state_drop" do
    let(:nic) {
      st = instance_double(Strand, label: "wait_rekey_old_state_drop")
      instance_double(Nic, strand: st, rekey_payload: {})
    }

    it "donates if policy update is ongoing" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)

      expect { nx.wait_old_state_drop }.to nap(5)
    end

    it "hops to wait if all is done" do
      t = Time.now
      expect(Time).to receive(:now).and_return(t)
      expect(nic.strand).to receive(:label).and_return("wait")
      expect(ps).to receive(:update).with(state: "waiting", last_rekey_at: t).and_return(true)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:rekey_payload).and_return({})
      expect(nic).to receive(:update).with(encryption_key: nil, rekey_payload: nil).and_return(true)
      expect { nx.wait_old_state_drop }.to hop("wait")
    end

    it "doesn't decrement refresh_keys if there are missed nics" do
      t = Time.now
      expect(Time).to receive(:now).and_return(t)
      expect(nic.strand).to receive(:label).and_return("wait")
      expect(ps).to receive(:update).with(state: "waiting", last_rekey_at: t).and_return(true)
      expect(nx).to receive(:rekeying_nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:update).with(encryption_key: nil, rekey_payload: nil).and_return(true)
      expect(nx).not_to receive(:decr_refresh_keys)
      expect { nx.wait_old_state_drop }.to hop("wait")
    end
  end

  describe ".random_private_ipv4" do
    it "returns a random private ipv4 range" do
      expect(described_class.random_private_ipv4("hetzner-hel1")).to be_a NetAddr::IPv4Net
    end

    it "finds a new subnet if the one it found is taken" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/12").twice
      expect(SecureRandom).to receive(:random_number).with(16383).and_return(1, 2)
      expect(PrivateSubnet).to receive(:[]).with(net4: "172.16.0.128/26", location: "hetzner-hel1").and_return([true])
      expect(PrivateSubnet).to receive(:[]).with(net4: "172.16.0.192/26", location: "hetzner-hel1").and_return(nil)
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

  describe ".create_tunnels" do
    let(:src_nic) {
      instance_double(Nic, id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b")
    }
    let(:dst_nic) {
      instance_double(Nic, id: "6a187cc1-291b-8eac-bdfc-96801fa3118d")
    }

    it "creates tunnels if not existing" do
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)
      nx.create_tunnels([src_nic, dst_nic], dst_nic)
    end

    it "skips existing tunnels" do
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(false)

      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)
      nx.create_tunnels([src_nic, dst_nic], dst_nic)
    end

    it "skips existing tunnels - 2" do
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(false)
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)

      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      nx.create_tunnels([src_nic, dst_nic], dst_nic)
    end
  end

  describe "#destroy" do
    let(:nic) {
      instance_double(Nic, vm_id: nil)
    }

    let(:vm) {
      Vm.new(family: "standard", cores: 1, name: "dummy-vm", location: "dummy-location").tap {
        _1.id = "788525ed-d6f0-4937-a844-323d4fd91946"
      }
    }

    it "extends deadline if a vm prevents destroy" do
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
      expect { nx.destroy }.to nap(1)
    end

    it "deletes and pops if nics are destroyed" do
      expect(ps).to receive(:destroy).and_return(true)
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:projects).and_return([prj]).at_least(:once)
      expect(ps).to receive(:dissociate_with_project).with(prj).and_return(true)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end
  end
end
