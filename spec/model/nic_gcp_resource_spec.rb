# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NicGcpResource do
  let(:project) { Project.create(name: "gcp-nic-res-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "ps", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "active"
    ) { it.id = SecureRandom.uuid }
  }

  let(:nic) {
    nic_id = SecureRandom.uuid
    Nic.create_with_id(nic_id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb::1",
      private_ipv4: "10.0.0.1",
      name: "test-nic",
      private_subnet_id: private_subnet.id,
      state: "active")
  }

  it "creates a NicGcpResource associated with a NIC" do
    resource = described_class.create_with_id(
      nic.id,
      address_name: "ubicloud-test-nic",
      static_ip: "35.192.0.1",
      network_name: "ubicloud-proj-test",
      subnet_name: "ubicloud-test",
      subnet_tag: "ps-test"
    )

    expect(resource).to be_a(described_class)
    expect(resource.id).to eq(nic.id)
    expect(resource.address_name).to eq("ubicloud-test-nic")
    expect(resource.static_ip).to eq("35.192.0.1")
    expect(resource.network_name).to eq("ubicloud-proj-test")
    expect(resource.subnet_name).to eq("ubicloud-test")
    expect(resource.subnet_tag).to eq("ps-test")
  end

  it "is associated with its NIC" do
    resource = described_class.create_with_id(nic.id)
    expect(resource.nic.id).to eq(nic.id)
  end
end
