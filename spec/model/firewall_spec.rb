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
      expect(fw).to receive(:private_subnet).and_return(private_subnet)
      expect(private_subnet).to receive(:incr_update_firewall_rules)
      fw.insert_firewall_rule("0.0.0.0/0", nil)
    end
  end
end
