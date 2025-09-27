# frozen_string_literal: true

RSpec.describe Prog::Vnet::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: Project.create(name: "test").id).tap { it.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
  }

  describe ".assemble" do
    it "fails if subnet doesn't exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "uses ipv6_addr if passed" do
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps)
      expect(ps).to receive(:random_private_ipv4).and_return("10.0.0.12/32")
      expect(ps).not_to receive(:random_private_ipv6)
      expect(described_class).to receive(:rand).and_return(123).exactly(6).times
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "7a:7b:7b:7b:7b:7b",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::NicNexus", label: "wait_allocation", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil}]).and_return(Strand.new)
      described_class.assemble(ps.id, ipv6_addr: "fd10:9b0b:6b4b:8fbb::/128", name: "demonic")
    end

    it "uses ipv4_addr if passed" do
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps)
      expect(ps).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/128")
      expect(ps).not_to receive(:random_private_ipv4)
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(described_class).to receive(:gen_mac).and_return("00:11:22:33:44:55")
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "00:11:22:33:44:55",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::NicNexus", label: "wait_allocation", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil}]).and_return(Strand.new)
      described_class.assemble(ps.id, ipv4_addr: "10.0.0.12/32", name: "demonic")
    end

    it "hops to create_aws_nic if location is aws" do
      expect(ps).to receive(:location).and_return(instance_double(Location, aws?: true)).at_least(:once)
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps).at_least(:once)
      expect(ps).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/128")
      expect(ps).to receive(:random_private_ipv4).and_return(NetAddr::IPv4Net.parse("10.0.0.0/26"))
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      expect(described_class).to receive(:gen_mac).and_return("00:11:22:33:44:55")
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.4/32",
        mac: "00:11:22:33:44:55",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::NicNexus", label: "create_aws_nic", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil}]).and_return(Strand.new)
      described_class.assemble(ps.id, name: "demonic")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#create_aws_nic" do
    it "naps if subnet is not created" do
      expect(nx).to receive(:nic).and_return(instance_double(Nic, private_subnet: instance_double(PrivateSubnet, strand: instance_double(Strand, label: "create_aws_vpc"))))
      expect { nx.create_aws_nic }.to nap(2)
    end

    it "hops to wait_aws_nic_created if subnet is created" do
      ps = Prog::Vnet::SubnetNexus.assemble(Project.create(name: "test").id)
      nic = described_class.assemble(ps.id, name: "demonic").subject
      ps.update(label: "wait")
      expect(nx).to receive(:bud).with(Prog::Aws::Nic, {"subject_id" => nic.id, "exclude_availability_zones" => nil, "availability_zone" => nil}, :create_subnet)
      expect(nx).to receive(:nic).and_return(nic).at_least(:once)
      expect { nx.create_aws_nic }.to hop("wait_aws_nic_created")
    end
  end

  describe "#wait_aws_nic_created" do
    it "reaps and hops to wait if leaf" do
      st.update(prog: "Vnet::NicNexus", label: "wait_aws_nic_created", stack: [{}])
      expect { nx.wait_aws_nic_created }.to hop("wait")
    end

    it "naps if not leaf" do
      st.update(prog: "Vnet::NicNexus", label: "wait_aws_nic_created", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Nic", label: "create_network_interface", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_nic_created }.to nap(1)
    end
  end

  describe "#wait_allocation" do
    it "naps if nothing to do" do
      expect { nx.wait_allocation }.to nap(5)
    end

    it "hops to wait_setup if allocated" do
      expect(nx).to receive(:when_vm_allocated_set?).and_yield
      expect { nx.wait_allocation }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    it "naps if nothing to do" do
      expect(nx).to receive(:decr_vm_allocated)
      expect { nx.wait_setup }.to nap(5)
    end

    it "incrs add_new_nic when setup_nic is set" do
      private_subnet = instance_double(PrivateSubnet)
      nic = instance_double(Nic, private_subnet: private_subnet)

      expect(nx).to receive(:nic).and_return(nic)
      expect(nx).to receive(:decr_vm_allocated)
      expect(nx).to receive(:when_setup_nic_set?).and_yield
      expect(nx).to receive(:decr_setup_nic)
      expect(private_subnet).to receive(:incr_add_new_nic)
      expect { nx.wait_setup }.to nap(5)
    end

    it "starts rekeying if setup is triggered" do
      expect(nx).to receive(:decr_vm_allocated)
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect { nx.wait_setup }.to hop("start_rekey")
    end
  end

  describe "#wait" do
    let(:nic) { instance_double(Nic, private_subnet: instance_double(PrivateSubnet, location: instance_double(Location, aws?: false), incr_refresh_keys: true)) }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "waits if location is aws" do
      expect(nic.private_subnet.location).to receive(:aws?).and_return(true)
      expect(nic).to receive(:semaphores).and_return([])
      expect { nx.wait }.to nap(60 * 60 * 24 * 365)
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
    let(:nic) { instance_double(Nic) }

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
    end

    it "if outbound setup is not triggered, just naps" do
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_return(false)
      expect { nx.wait_rekey_outbound_trigger }.to nap(5)
    end

    it "if outbound setup is triggered, pushes setup_outbound and naps" do
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_yield
      expect(nx).to receive(:decr_trigger_outbound_update)
      expect(nx).to receive(:push).with(Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound)
      expect { nx.wait_rekey_outbound_trigger }.to nap(5)
    end

    it "hops to wait_rekey_old_state_drop_trigger if outbound_setup is completed" do
      expect(nx).to receive(:retval).and_return({"msg" => "outbound_setup is complete"})
      expect { nx.wait_rekey_outbound_trigger }.to hop("wait_rekey_old_state_drop_trigger")
    end

    it "wait_rekey_old_state_drop_trigger naps if trigger is not set" do
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_return(false)

      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(5)
    end

    it "wait_rekey_old_state_drop_trigger pushes drop_old_state and naps if trigger is set" do
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_yield
      expect(nx).to receive(:decr_old_state_drop_trigger)
      expect(nx).to receive(:push).with(Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state)
      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(5)
    end

    it "hops to wait if drop_old_state is completed" do
      expect(nx).to receive(:retval).and_return({"msg" => "drop_old_state is complete"})
      expect { nx.wait_rekey_old_state_drop_trigger }.to hop("wait")
    end
  end

  describe "#destroy" do
    let(:ps) {
      PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: Project.create(name: "test").id)
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { it.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }
    let(:ipsec_tunnels) {
      [
        instance_double(IpsecTunnel),
        instance_double(IpsecTunnel)
      ]
    }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "destroys nic" do
      expect(nic).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(ps).to receive(:incr_refresh_keys).and_return(true)
      expect(nic).to receive(:destroy).and_return(true)
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end

    it "fails if there is vm attached" do
      expect(nic).to receive(:vm).and_return(true)
      expect { nx.destroy }.to nap(5)
    end

    it "buds aws nic destroy if location is aws" do
      location_id = Location.create(name: "us-west-2", provider: "aws", project_id: ps.project_id, display_name: "us-west-2", ui_name: "us-west-2", visible: true).id
      nic.update(private_subnet_id: ps.id)
      ps.update(location_id:)
      st.update(prog: "Vnet::NicNexus", label: "destroy", stack: [{}])
      child = Strand.create(parent_id: st.id, prog: "Aws::Nic", label: "start", stack: [{}])
      expect(nx).to receive(:bud).with(Prog::Aws::Nic, {"subject_id" => nic.id}, :destroy)
      expect { nx.destroy }.to hop("wait_aws_nic_destroyed")
      expect(Semaphore[strand_id: child.id, name: "destroy"]).not_to be_nil
    end
  end

  describe "#wait_aws_nic_destroyed" do
    it "reaps and destroys nic if leaf" do
      st.update(prog: "Vnet::NicNexus", label: "wait_aws_nic_destroyed", stack: [{}])
      nic = instance_double(Nic, id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      expect(nx).to receive(:nic).and_return(nic).at_least(:once)
      expect(nic).to receive(:destroy)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:incr_refresh_keys)
      expect { nx.wait_aws_nic_destroyed }.to exit({"msg" => "nic deleted"})
    end

    it "naps if not leaf" do
      st.update(prog: "Vnet::NicNexus", label: "wait_aws_nic_destroyed", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Aws::Nic", label: "destroy", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_aws_nic_destroyed }.to nap(10)
    end
  end

  describe "nic fetch" do
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { it.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }

    before do
      nx.instance_variable_set(:@nic, nic)
    end

    it "returns nic" do
      expect(nx.nic).to eq(nic)
    end
  end
end
