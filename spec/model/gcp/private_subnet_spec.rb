# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PrivateSubnet do
  let(:project) { Project.create(name: "gcp-ps-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:subnet1) {
    described_class.create(
      name: "ps1", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "active",
    )
  }

  let(:subnet2) {
    described_class.create(
      name: "ps2", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:9fbb::/64", net4: "10.0.1.0/26", state: "active",
    )
  }

  context "with GCP provider" do
    it "raises error on connect_subnet" do
      expect { subnet1.connect_subnet(subnet2) }.to raise_error("Connected subnets are not supported for GCP")
    end

    it "raises error on disconnect_subnet" do
      expect { subnet1.disconnect_subnet(subnet2) }.to raise_error("Connected subnets are not supported for GCP")
    end

    it "reserves first 2 and last 2 addresses when picking a random IPv4" do
      subnet1
      # /26 (64 addresses) - 2 (network + gateway) - 2 (second-to-last + broadcast) = 60
      expect(SecureRandom).to receive(:random_number).with(60).and_return(0)
      expect(subnet1.random_private_ipv4.to_s).to eq "10.0.0.2/32"
    end
  end
end
