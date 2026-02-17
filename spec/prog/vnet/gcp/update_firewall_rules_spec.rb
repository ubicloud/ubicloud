# frozen_string_literal: true

RSpec.describe Prog::Vnet::Gcp::UpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:vm) { instance_double(Vm) }

  before do
    nx.instance_variable_set(:@vm, vm)
  end

  describe "#before_run" do
    it "pops if vm is to be destroyed" do
      expect(vm).to receive(:destroy_set?).and_return(true)
      expect { nx.before_run }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pop if vm is not to be destroyed" do
      expect(vm).to receive(:destroy_set?).and_return(false)
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    it "pops with firewall rule added message" do
      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
