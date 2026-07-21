# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe Address do
  let(:routed_to_host_id) { "46683a25-acb1-4371-afe9-d39f303e44b4" }

  it "does not allow IPv4 subnets larger than /24" do
    address = described_class.new(cidr: "0.0.0.0/23", routed_to_host_id:)
    expect(address.valid?).to be false
    expect(address.errors[:cidr]).to eq ["too large (contains more than 256 addresses)"]
  end

  it "allows IPv4 subnets up to /24" do
    address = described_class.new(cidr: "0.0.0.0/24", routed_to_host_id:)
    expect(address.valid?).to be true
  end

  it "populates ipv4_address table with addresses in cidr" do
    vm_host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    address = described_class.create(cidr: "0.0.0.0/30", vm_host:)
    expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.0 0.0.0.1 0.0.0.2 0.0.0.3]
    address.destroy
    expect(DB[:ipv4_address]).to be_empty
  end

  it "does not populate host sshable address" do
    Prog::Vm::HostNexus.assemble("1.1.1.1").subject
    expect(described_class.count).to eq 1
    expect(Sshable.count).to eq 1
    expect(described_class.get(:cidr).network.to_s).to eq Sshable.get(:host)
    expect(DB[:ipv4_address]).to be_empty
  end

  describe "leaseweb" do
    # Leaseweb routes whole blocks to the host, so assemble pulls them from the
    # API rather than deriving one address from the sshable host.
    def assemble_leaseweb_host
      allow(Config).to receive_messages(
        leaseweb_connection_string: "https://api.leaseweb.com",
        leaseweb_api_key: "key123",
      )
      Excon.stub({path: "/bareMetals/v2/servers/1/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(
          ips: [{ip: "1.2.3.4/24", prefixLength: 24, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: true, gateway: "1.2.3.254"}],
          _metadata: {totalCount: 1},
        )})
      Prog::Vm::HostNexus.assemble("1.2.3.4", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "1").subject
    end

    it "populates ipv4_address table with addresses in cidr without first and last" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "0.0.0.0/30", vm_host:)
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.1 0.0.0.2]
    end

    # A /32 Leaseweb routes here is not a block: dropping a network and a
    # broadcast address would leave nothing behind.
    it "keeps the only address of a standalone ip" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "5.6.7.8/32", vm_host:)
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[5.6.7.8]
    end

    it "keeps both addresses of a two address block" do
      vm_host = assemble_leaseweb_host
      described_class.create(cidr: "5.6.7.8/31", vm_host:)
      expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[5.6.7.8 5.6.7.9]
    end
  end
end
