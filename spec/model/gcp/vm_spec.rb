# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Vm do
  let(:project) { Project.create(name: "gcp-vm-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:vm) {
    create_vm(
      project_id: project.id,
      location_id: location.id,
      name: "gcp-test-vm",
      memory_gib: 8
    )
  }

  context "with GCP provider" do
    describe "#ip6" do
      it "returns the first IPv6 address from ephemeral_net6" do
        vm.update(ephemeral_net6: "2600:1900:4000:1::1/128")
        expect(vm.ip6.to_s).to eq("2600:1900:4000:1::1")
      end

      it "returns nil when ephemeral_net6 is nil" do
        vm.update(ephemeral_net6: nil)
        expect(vm.ip6).to be_nil
      end
    end

    describe "#update_firewall_rules_prog" do
      it "returns the GCP UpdateFirewallRules prog class" do
        expect(vm.update_firewall_rules_prog).to eq(Prog::Vnet::Gcp::UpdateFirewallRules)
      end
    end
  end
end
