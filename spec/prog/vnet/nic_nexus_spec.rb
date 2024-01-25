# frozen_string_literal: true

RSpec.describe Prog::Vnet::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting").tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
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
      expect(Nic).to receive(:create).with(
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "7a:7b:7b:7b:7b:7b",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic"
      ).and_return(true)
      expect(Strand).to receive(:create).with(prog: "Vnet::NicNexus", label: "wait_vm").and_yield(Strand.new).and_return(Strand.new)
      described_class.assemble(ps.id, ipv6_addr: "fd10:9b0b:6b4b:8fbb::/128", name: "demonic")
    end

    it "uses ipv4_addr if passed" do
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps)
      expect(ps).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/128")
      expect(ps).not_to receive(:random_private_ipv4)
      expect(described_class).to receive(:gen_mac).and_return("00:11:22:33:44:55")
      expect(Nic).to receive(:create).with(
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "00:11:22:33:44:55",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic"
      ).and_return(true)
      expect(Strand).to receive(:create).with(prog: "Vnet::NicNexus", label: "wait_vm").and_yield(Strand.new).and_return(Strand.new)
      described_class.assemble(ps.id, ipv4_addr: "10.0.0.12/32", name: "demonic")
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

  describe "#wait_vm" do
    let(:ps) {
      PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting").tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "naps 60 if nothing to do and vm doesn't exist" do
      expect { nx.wait_vm }.to nap(60)
    end

    it "naps 1 if nothing to do and vm exists" do
      vm = instance_double(Vm)
      expect(nic).to receive(:vm).and_return(vm)
      expect { nx.wait_vm }.to nap(1)
    end

    it "starts setup and pings subnet" do
      vm = instance_double(Vm)
      expect(nic).to receive(:vm).and_return(vm)
      expect(nx).to receive(:when_setup_nic_set?).and_yield
      expect { nx.wait_vm }.to hop("add_subnet_addr")
    end
  end

  describe "#add_subnet_addr" do
    it "buds RekeyNicTunnel with add_subnet_addr" do
      expect(nx).to receive(:bud).with(Prog::Vnet::RekeyNicTunnel, {}, :add_subnet_addr)
      expect { nx.add_subnet_addr }.to hop("wait_add_subnet_addr")
    end
  end

  describe "#wait_add_subnet_addr" do
    let(:nic) { instance_double(Nic) }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "donates if nothing to do" do
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:leaf?).and_return(false)
      expect { nx.wait_add_subnet_addr }.to nap(0)
    end

    it "starts to wait_setup and pings subnet" do
      ps = instance_double(PrivateSubnet)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:incr_add_new_nic)

      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx).to receive(:reap).and_return(true)
      expect { nx.wait_add_subnet_addr }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    it "naps if nothing to do" do
      expect { nx.wait_setup }.to nap(5)
    end

    it "starts rekeying if setup is triggered" do
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect(nx).to receive(:decr_setup_nic)
      expect { nx.wait_setup }.to hop("start_rekey")
    end
  end

  describe "#wait" do
    it "naps if nothing to do" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to detach vm if needed" do
      expect(nx).to receive(:when_detach_vm_set?).and_yield
      expect { nx.wait }.to hop("detach_vm")
    end

    it "hops to start rekey if needed" do
      expect(nx).to receive(:when_start_rekey_set?).and_yield
      expect { nx.wait }.to hop("start_rekey")
    end

    it "hops to repopulate if needed" do
      expect(nx).to receive(:when_repopulate_set?).and_yield
      expect { nx.wait }.to hop("repopulate")
    end
  end

  describe "#repopulate" do
    it "buds RekeyNicTunnel with add_subnet_addr" do
      expect(nx).to receive(:bud).with(Prog::Vnet::RekeyNicTunnel, {}, :add_subnet_addr)
      expect { nx.repopulate }.to hop("wait_repopulate")
    end
  end

  describe "#wait_repopulate" do
    let(:nic) { instance_double(Nic) }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "donates if nothing to do" do
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:leaf?).and_return(false)
      expect { nx.wait_repopulate }.to nap(0)
    end

    it "starts to wait and increments refresh_keys if bud is complete" do
      ps = instance_double(PrivateSubnet)
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:incr_refresh_keys)

      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx).to receive(:reap).and_return(true)
      expect { nx.wait_repopulate }.to hop("wait")
    end
  end

  describe "#rekey" do
    let(:nic) { instance_double(Nic) }

    before do
      allow(nx).to receive(:nic).and_return(nic)
    end

    it "buds rekey with setup_inbound and hops to wait_rekey_inbound" do
      expect(nx).to receive(:bud).with(Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound).and_return(true)
      expect { nx.start_rekey }.to hop("wait_rekey_inbound")
    end

    it "reaps and donates if setup_inbound is continuing" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:reap).and_return(true)
      expect { nx.wait_rekey_inbound }.to nap(0)
    end

    it "reaps and hops to wait_rekey_outbound_trigger if setup_inbound is completed" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:decr_start_rekey).and_return(true)
      expect { nx.wait_rekey_inbound }.to hop("wait_rekey_outbound_trigger")
    end

    it "if outbound setup is not triggered, just donate" do
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_return(false)
      expect { nx.wait_rekey_outbound_trigger }.to nap(5)
    end

    it "if outbound setup is triggered, hops to setup_outbound" do
      expect(nx).to receive(:when_trigger_outbound_update_set?).and_yield
      expect(nx).to receive(:bud).with(Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound).and_return(true)
      expect { nx.wait_rekey_outbound_trigger }.to hop("wait_rekey_outbound")
    end

    it "wait_rekey_outbound reaps and donates if setup_outbound is continuing" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:donate).and_return(true)
      nx.wait_rekey_outbound
    end

    it "wait_rekey_outbound reaps and hops to wait_rekey_old_state_drop_trigger if setup_outbound is completed" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:decr_trigger_outbound_update).and_return(true)
      expect { nx.wait_rekey_outbound }.to hop("wait_rekey_old_state_drop_trigger")
    end

    it "wait_rekey_old_state_drop_trigger donates if trigger is not set" do
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_return(false)

      expect { nx.wait_rekey_old_state_drop_trigger }.to nap(5)
    end

    it "wait_rekey_old_state_drop_trigger hops to wait_rekey_old_state_drop if trigger is set" do
      expect(nx).to receive(:when_old_state_drop_trigger_set?).and_yield
      expect(nx).to receive(:bud).with(Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state).and_return(true)
      expect { nx.wait_rekey_old_state_drop_trigger }.to hop("wait_rekey_old_state_drop")
    end

    it "wait_rekey_old_state_drop reaps and donates if drop_old_state is continuing" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:donate).and_return(true)
      nx.wait_rekey_old_state_drop
    end

    it "wait_rekey_old_state_drop reaps and hops to wait if drop_old_state is completed" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect(nx).to receive(:reap).and_return(true)
      expect(nx).to receive(:decr_old_state_drop_trigger).and_return(true)
      expect { nx.wait_rekey_old_state_drop }.to hop("wait")
    end
  end

  describe "#destroy" do
    let(:ps) {
      PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting").tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
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
      expect(ipsec_tunnels[0]).to receive(:destroy).and_return(true)
      expect(ipsec_tunnels[1]).to receive(:destroy).and_return(true)
      expect(nic).to receive(:src_ipsec_tunnels_dataset).and_return(ipsec_tunnels[0])
      expect(nic).to receive(:dst_ipsec_tunnels_dataset).and_return(ipsec_tunnels[1])
      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:incr_refresh_keys).and_return(true)
      expect(nic).to receive(:destroy).and_return(true)
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end

    it "fails if there is vm attached" do
      expect(nic).to receive(:vm).and_return(true)
      expect { nx.destroy }.to nap(5)
    end
  end

  describe "#detach_vm" do
    let(:ps) {
      PrivateSubnet.create_with_id(name: "ps", location: "hetzner-hel1", net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting").tap { _1.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
    }
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
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

    it "detaches vm and refreshes mesh" do
      expect(nic).to receive(:update).with(vm_id: nil).and_return(true)
      expect(nic).to receive(:src_ipsec_tunnels_dataset).and_return(ipsec_tunnels[0])
      expect(ipsec_tunnels[0]).to receive(:destroy).and_return(true)
      expect(nic).to receive(:dst_ipsec_tunnels_dataset).and_return(ipsec_tunnels[1])
      expect(ipsec_tunnels[1]).to receive(:destroy).and_return(true)

      expect(nic).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:incr_refresh_keys).and_return(true)

      expect { nx.detach_vm }.to hop("wait")
    end
  end

  describe "nic fetch" do
    let(:nic) {
      Nic.new(private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic").tap { _1.id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e" }
    }

    before do
      nx.instance_variable_set(:@nic, nic)
    end

    it "returns nic" do
      expect(nx.nic).to eq(nic)
    end
  end
end
