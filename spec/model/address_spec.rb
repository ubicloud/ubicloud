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
    address.populate_ipv4_addresses
    expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.0 0.0.0.1 0.0.0.2 0.0.0.3].freeze
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

  # The provider names the addresses of a block it reserves, such as its
  # network and broadcast address; the pool never offers them to a VM.
  it "leaves reserved addresses out of the pool" do
    vm_host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    described_class.create(cidr: "0.0.0.0/30", vm_host:).populate_ipv4_addresses(reserved: ["0.0.0.0", "0.0.0.3"])
    expect(DB[:ipv4_address].select_order_map(:ip).map(&:to_s)).to eq %w[0.0.0.1 0.0.0.2]
  end
end
