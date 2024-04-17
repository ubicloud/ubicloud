# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Firewall do
  describe "Firewall" do
    let(:fw) {
      described_class.create_with_id(name: "test-fw", description: "test fw desc")
    }

    it "inserts firewall rules" do
      fw.insert_firewall_rule("10.0.0.16/28", Sequel.pg_range(80..5432))
      expect(fw.firewall_rules.count).to eq(1)
      expect(fw.firewall_rules.first.cidr.to_s).to eq("10.0.0.16/28")
      pr = fw.firewall_rules.first.port_range
      expect(pr.begin).to eq(80)
      expect(pr.end).to eq(5433)
    end

    it "increments VMs update_firewall_rules if there is a VM" do
      private_subnet = instance_double(PrivateSubnet)
      expect(fw).to receive(:private_subnets).and_return([private_subnet])
      expect(private_subnet).to receive(:incr_update_firewall_rules)
      fw.insert_firewall_rule("0.0.0.0/0", nil)
    end

    it "associates with a private subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      expect(ps).to receive(:incr_update_firewall_rules)
      fw.associate_with_private_subnet(ps)

      expect(fw.private_subnets.count).to eq(1)
      expect(fw.private_subnets.first.id).to eq(ps.id)
    end

    it "disassociates from a private subnet" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      fw.associate_with_private_subnet(ps, apply_firewalls: false)
      expect(fw.private_subnets.count).to eq(1)

      expect(ps).to receive(:incr_update_firewall_rules)
      fw.disassociate_from_private_subnet(ps)
      expect(fw.reload.private_subnets.count).to eq(0)
      expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
    end

    it "disassociates from a private subnet without applying firewalls" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      fw.associate_with_private_subnet(ps, apply_firewalls: false)
      expect(fw.private_subnets.count).to eq(1)

      expect(ps).not_to receive(:incr_update_firewall_rules)
      fw.disassociate_from_private_subnet(ps, apply_firewalls: false)
      expect(fw.reload.private_subnets.count).to eq(0)
      expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
    end

    it "destroys firewall" do
      ps = PrivateSubnet.create_with_id(name: "test-ps", location: "hetzner-hel1", net6: "2001:db8::/64", net4: "10.0.0.0/24")
      fw.associate_with_private_subnet(ps, apply_firewalls: false)
      expect(fw.reload.private_subnets.count).to eq(1)
      expect(fw.private_subnets).to receive(:map).and_return([ps])
      expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(1)
      fw.destroy
      expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
      expect(described_class[fw.id]).to be_nil
    end
  end
end
