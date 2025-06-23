# frozen_string_literal: true

RSpec.describe Prog::Vnet::SubnetNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:prj) { Project.create_with_id(name: "default") }
  let(:ps) {
    PrivateSubnet.create_with_id(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
  }

  let(:ps2) {
    PrivateSubnet.create_with_id(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fcc::/64",
      net4: "1.1.1.128/26", state: "waiting", project_id: prj.id)
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

    it "fails if location doesn't exist" do
      expect {
        described_class.assemble(prj.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "uses ipv6_addr if passed and creates entities" do
      expect(described_class).to receive(:random_private_ipv4).and_return("10.0.0.0/26")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location_id: Location::HETZNER_FSN1_ID,
        ipv6_range: "fd10:9b0b:6b4b:8fbb::/64"
      )

      expect(ps.subject.net6.to_s).to eq("fd10:9b0b:6b4b:8fbb::/64")
    end

    it "uses ipv4_addr if passed and creates entities" do
      expect(described_class).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/64")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location_id: Location::HETZNER_FSN1_ID,
        ipv4_range: "10.0.0.0/26"
      )

      expect(ps.subject.net4.to_s).to eq("10.0.0.0/26")
    end

    it "uses firewall if provided" do
      fw = Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: prj.id)
      ps = described_class.assemble(prj.id, firewall_id: fw.id)
      expect(ps.subject.firewalls.count).to eq(1)
      expect(ps.subject.firewalls.first).to eq(fw)
    end

    it "fails if provided firewall does not exist" do
      expect {
        described_class.assemble(prj.id, firewall_id: "550e8400-e29b-41d4-a716-446655440000")
      }.to raise_error RuntimeError, "Firewall with id 550e8400-e29b-41d4-a716-446655440000 and location hetzner-fsn1 does not exist"
    end

    it "fails if firewall is not in the project" do
      fw = Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Project.create(name: "t2").id)
      expect {
        described_class.assemble(prj.id, firewall_id: fw.id)
      }.to raise_error RuntimeError, "Firewall with id #{fw.id} and location hetzner-fsn1 does not exist"
    end

    it "fails if both allow_only_ssh and firewall_id are specified" do
      fw = Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: prj.id)
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
    it "creates a vpc if location is aws and starts to wait for it" do
      loc = Location.create_with_id(name: "aws-us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
      expect(ps).to receive(:location).and_return(loc).at_least(:once)
      expect(nx).to receive(:bud).with(Prog::Aws::Vpc, {"subject_id" => ps.id}, :create_vpc)
      expect { nx.start }.to hop("wait_vpc_created")
    end

    it "does not create the PrivateSubnetAwsResource if it already exists" do
      loc = Location.create_with_id(name: "aws-us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
      expect(ps).to receive(:location).and_return(loc).at_least(:once)
      expect(ps).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, id: "123")).at_least(:once)
      expect(nx).to receive(:bud).with(Prog::Aws::Vpc, {"subject_id" => ps.id}, :create_vpc)
      expect { nx.start }.to hop("wait_vpc_created")
      expect(PrivateSubnetAwsResource.count).to eq(0)
    end

    it "hops to wait if location is not aws" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait_vpc_created" do
    it "reaps and hops to wait if leaf" do
      st.update(prog: "Vnet::SubnetNexus", label: "wait_vpc_created", stack: [{}])
      expect { nx.wait_vpc_created }.to hop("wait")
    end

    it "naps if not leaf" do
      st.update(prog: "Vnet::SubnetNexus", label: "wait_vpc_created", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Vpc", label: "create_vpc", stack: [{}], lease: Time.now + 10)
      # Cover case where reap without reaper argument has results in reapable children
      Strand.create(parent_id: st.id, prog: "Aws::Vpc", label: "create_vpc", stack: [{}]).this.update(exitval: '"subnet created"')
      expect { nx.wait_vpc_created }.to nap(2)
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

    it "hops to wait_policy_updated if state creation is done" do
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

  describe ".random_private_ipv4" do
    it "returns a random private ipv4 range" do
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], prj)).to be_a NetAddr::IPv4Net
    end

    it "finds a new subnet if the one it found is taken" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("10.0.0.0/8").at_least(:once)
      project = Project.create_with_id(name: "test-project")
      described_class.assemble(project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-subnet", ipv4_range: "10.0.0.128/26")
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 8) - 1).and_return(1, 2)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project).to_s).to eq("10.0.0.192/26")
    end

    it "finds a new subnet if the one it found is banned" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/16", "10.0.0.0/8")
      project = Project.create_with_id(name: "test-project")
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 16) - 1).and_return(1)
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 8) - 1).and_return(1)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project).to_s).to eq("10.0.0.128/26")
    end

    it "finds a new subnet if the initial range is smaller than the requested cidr range" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/16", "10.0.0.0/8")
      project = Project.create_with_id(name: "test-project")
      expect(SecureRandom).not_to receive(:random_number).with(2**(16 - 16) - 1)
      allow(SecureRandom).to receive(:random_number).with(2**(16 - 8) - 1).and_return(15)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 16).to_s).to eq("10.16.0.0/16")
    end

    it "raises an error when invalid CIDR is given" do
      project = Project.create_with_id(name: "test-project")
      expect { described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 33) }.to raise_error(ArgumentError)
    end
  end

  describe ".random_private_ipv6" do
    it "returns a random private ipv6 range" do
      expect(described_class.random_private_ipv6(Location[name: "hetzner-fsn1"], prj)).to be_a NetAddr::IPv6Net
    end

    it "finds a new subnet if the one it found is taken" do
      project = Project.create_with_id(name: "test-project")
      described_class.assemble(project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-subnet", ipv6_range: "fd61:6161:6161:6161::/64")
      expect(SecureRandom).to receive(:bytes).with(7).and_return("a" * 7, "b" * 7)
      expect(described_class.random_private_ipv6(Location[name: "hetzner-fsn1"], project).to_s).to eq("fd62:6262:6262:6262::/64")
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

    it "hops to wait_aws_vpc_destroyed if location is aws" do
      expect(ps).to receive(:location).and_return(Location.create_with_id(name: "aws-us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true))
      expect(nx).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_destroy)
      expect(nx).to receive(:bud).with(Prog::Aws::Vpc, {"subject_id" => ps.id}, :destroy)
      expect { nx.destroy }.to hop("wait_aws_vpc_destroyed")
    end

    it "increments the destroy semaphore of nics" do
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(nic).to receive(:incr_destroy).and_return(true)
      expect { nx.destroy }.to nap(1)
    end

    it "deletes and pops if nics are destroyed" do
      expect(ps).to receive(:destroy).and_return(true)
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "disconnects all subnets" do
      prj = Project.create_with_id(name: "test-project")
      ps1 = described_class.assemble(prj.id, name: "ps1").subject
      ps2 = described_class.assemble(prj.id, name: "ps2").subject
      ps1.connect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id)).to eq [ps1.id]

      expect(nx).to receive(:private_subnet).and_return(ps1).at_least(:once)
      expect(ps1).to receive(:disconnect_subnet).with(ps2).and_call_original
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end
  end

  describe "#wait_aws_vpc_destroyed" do
    it "deletes the vpc and pops if leaf" do
      st.update(prog: "Vnet::SubnetNexus", label: "wait_aws_vpc_destroyed", stack: [{}])
      expect(nx).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(ps).to receive(:destroy).and_return(true)
      expect(ps).to receive(:private_subnet_aws_resource).and_return(instance_double(PrivateSubnetAwsResource, id: "123", destroy: true))
      expect { nx.wait_aws_vpc_destroyed }.to exit({"msg" => "vpc destroyed"})
    end

    it "naps if not leaf" do
      st.update(prog: "Vnet::SubnetNexus", label: "wait_aws_vpc_destroyed", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Vpc", label: "destroy", stack: [{}])
      expect { nx.wait_aws_vpc_destroyed }.to nap(10)
    end
  end
end
