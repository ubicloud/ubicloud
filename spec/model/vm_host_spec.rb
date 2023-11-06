# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe VmHost do
  subject(:vh) {
    described_class.new(
      net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
      ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
    )
  }

  let(:cidr) { NetAddr::IPv4Net.parse("0.0.0.0/30") }
  let(:address) {
    Address.new(
      cidr: cidr,
      routed_to_host_id: "46683a25-acb1-4371-afe9-d39f303e44b4"
    )
  }
  let(:assigned_host_address) {
    AssignedHostAddress.new(
      ip: cidr,
      address_id: address.id,
      host_id: "46683a25-acb1-4371-afe9-d39f303e44b4"
    )
  }
  let(:hetzner_ips) {
    [
      ["1.1.1.0/30", "1.1.1.1", true],
      ["1.1.1.2/32", "1.1.0.0", true],
      ["1.1.1.3/32", "1.1.1.1", false],
      ["2a01:4f8:10a:128b::/64", "1.1.1.1", true]
    ].map {
      Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
    }
  }

  it "requires an Sshable too" do
    expect {
      sa = Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      described_class.create(location: "test-location") { _1.id = sa.id }
    }.not_to raise_error
  end

  it "can generate random ipv6 subnets" do
    expect(vh.ip6_random_vm_network.contains(vh.ip6)).to be false
  end

  it "crashes if the prefix length for a VM is shorter than the host's prefix" do
    expect {
      vh.ip6_reserved_network(1)
    }.to raise_error RuntimeError, "BUG: host prefix must be is shorter than reserved prefix"
  end

  it "has no ipv6 reserved network when vendor used NDP" do
    expect(vh).to receive(:ip6).and_return(nil)
    expect(vh.ip6_reserved_network).to be_nil
  end

  it "tries to get another random network if the proposal matches the reserved nework" do
    expect(SecureRandom).to receive(:bytes).and_return("\0\0")
    expect(SecureRandom).to receive(:bytes).and_call_original
    expect(vh.ip6_random_vm_network.to_s).not_to eq(vh.ip6_reserved_network)
  end

  it "has a shortcut to install Rhizome" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("InstallRhizome")
      expect(args[:stack]).to eq([subject_id: vh.id, target_folder: "host", install_specs: false])
    end
    vh.install_rhizome
  end

  it "has a shortcut to download a new boot image" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("DownloadBootImage")
      expect(args[:stack]).to eq([subject_id: vh.id, image_name: "my-image", custom_url: "https://example.com/my-image.raw"])
    end
    vh.download_boot_image("my-image", "https://example.com/my-image.raw")
  end

  it "assigned_subnets returns the assigned subnets" do
    expect(vh).to receive(:assigned_subnets).and_return([address])
    expect(vh).to receive(:vm_addresses).and_return([])
    expect(SecureRandom).to receive(:random_number).with(4).and_return(0)
    expect(vh).to receive(:sshable).and_return(instance_double(Sshable, host: "0.0.0.2")).at_least(:once)
    ip4, r_address = vh.ip4_random_vm_network
    expect(ip4.to_s).to eq("0.0.0.0")
    expect(r_address).to eq(address)
  end

  it "returns nil if there is no available subnet" do
    expect(vh).to receive(:assigned_subnets).and_return([address])
    expect(address.assigned_vm_address).to receive(:count).and_return(4)
    expect(vh).to receive(:sshable).and_return(instance_double(Sshable, host: "0.0.0.2")).at_least(:once)
    ip4, address = vh.ip4_random_vm_network
    expect(ip4).to be_nil
    expect(address).to be_nil
  end

  it "finds another address if it's already assigned" do
    expect(vh).to receive(:assigned_subnets).and_return([address]).at_least(:once)
    expect(vh).to receive(:vm_addresses).and_return([instance_double(AssignedVmAddress, ip: NetAddr::IPv4Net.parse("0.0.0.0"))]).at_least(:once)
    expect(vh).to receive(:sshable).and_return(instance_double(Sshable, host: "0.0.0.2")).at_least(:once)
    expect(SecureRandom).to receive(:random_number).with(4).and_return(0, 1)
    ip4, r_address = vh.ip4_random_vm_network
    expect(ip4.to_s).to eq("0.0.0.1")
    expect(r_address).to eq(address)
  end

  it "returns vm_addresses" do
    vm = instance_double(Vm, assigned_vm_address: address)
    expect(vh).to receive(:vms).and_return([vm])
    expect(vh.vm_addresses).to eq([address])
  end

  it "sshable_address returns the sshable address" do
    expect(vh).to receive(:assigned_host_addresses).and_return([assigned_host_address])
    expect(vh.sshable_address).to eq(assigned_host_address)
  end

  it "hetznerifies a host" do
    expect(vh).to receive(:create_addresses).at_least(:once)
    expect(HetznerHost).to receive(:create).with(server_identifier: "12").and_return(true)

    vh.hetznerify("12")
  end

  it "reset server fails for non development" do
    expect(Config).to receive(:development?).and_return(false)
    expect {
      vh.reset
    }.to raise_error(RuntimeError, "BUG: reset is only allowed in development")
  end

  it "resets the server in development" do
    expect(Config).to receive(:development?).and_return(true)
    expect(Hosting::Apis).to receive(:reset_server).with(vh)
    vh.reset
  end

  it "create_addresses fails if a failover ip of non existent server is being added" do
    expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
    expect(vh).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
    Sshable.create(host: "test.localhost") { _1.id = vh.id }
    described_class.create(location: "test-location") { _1.id = vh.id }

    expect(vh).to receive(:assigned_subnets).and_return([]).at_least(:once)
    expect { vh.create_addresses }.to raise_error(RuntimeError, "BUG: source host 1.1.1.1 isn't added to the database")
  end

  it "create_addresses creates given addresses and doesn't make an api call when ips given" do
    expect(vh).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
    Sshable.create(host: "1.1.0.0") { _1.id = vh.id }
    Sshable.create_with_id(host: "1.1.1.1")

    described_class.create(location: "test-location") { _1.id = vh.id }

    expect(vh).to receive(:assigned_subnets).and_return([]).at_least(:once)
    vh.create_addresses(ip_records: hetzner_ips)

    expect(Address.where(routed_to_host_id: vh.id).count).to eq(4)
  end

  it "create_addresses creates addresses" do
    expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
    expect(vh).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
    Sshable.create(host: "1.1.0.0") { _1.id = vh.id }
    Sshable.create_with_id(host: "1.1.1.1")

    described_class.create(location: "test-location") { _1.id = vh.id }

    expect(vh).to receive(:assigned_subnets).and_return([]).at_least(:once)
    vh.create_addresses

    expect(Address.where(routed_to_host_id: vh.id).count).to eq(4)
  end

  it "create_addresses returns immediately if there are no addresses to create" do
    expect(Hosting::Apis).to receive(:pull_ips).and_return(nil)
    vh.create_addresses
    expect(Address.where(routed_to_host_id: vh.id).count).to eq(0)
  end

  it "skips already assigned subnets" do
    expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
    expect(vh).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
    Sshable.create(host: "1.1.0.0") { _1.id = vh.id }
    Sshable.create_with_id(host: "1.1.1.1")
    described_class.create(location: "test-location") { _1.id = vh.id }

    expect(vh).to receive(:assigned_subnets).and_return([Address.new(cidr: NetAddr::IPv4Net.parse("1.1.1.0/30".shellescape))]).at_least(:once)
    vh.create_addresses
    expect(Address.where(routed_to_host_id: vh.id).count).to eq(3)
  end

  it "updates the routed_to_host_id if the address is reassigned to another host and there is no vm using the ip range" do
    hetzner_ips = [
      Hosting::HetznerApis::IpInfo.new(ip_address: "1.1.1.0/30", source_host_ip: "1.1.1.1", is_failover: true)
    ]
    old_id = "4c5dc171-a116-4a05-9e6d-381a4b382b71"
    new_id = "46683a25-acb1-4371-afe9-d39f303e44b4"

    expect(vh).to receive(:id).and_return(new_id).at_least(:once)
    expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)

    Sshable.create(host: "1.1.0.0") { _1.id = old_id }
    described_class.create(location: "test-location") { _1.id = old_id }

    Sshable.create_with_id(host: "1.1.1.1")
    adr = Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: old_id)
    expect(Address).to receive(:where).with(cidr: "1.1.1.0/30").and_return([adr]).once

    expect(adr).to receive(:update).with(routed_to_host_id: new_id).and_return(true)
    vh.create_addresses
  end

  it "fails if the ip range is already assigned to a vm" do
    hetzner_ips = [
      Hosting::HetznerApis::IpInfo.new(ip_address: "1.1.1.0/30", source_host_ip: "1.1.1.1", is_failover: true)
    ]
    old_id = "4c5dc171-a116-4a05-9e6d-381a4b382b71"
    expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)

    Sshable.create(host: "1.1.0.0") { _1.id = old_id }
    described_class.create(location: "test-location") { _1.id = old_id }

    adr = Address.create_with_id(cidr: "1.1.1.0/30", routed_to_host_id: old_id)
    expect(Address).to receive(:where).with(cidr: "1.1.1.0/30").and_return([adr]).once

    expect(adr).to receive(:assigned_vm_address).and_return([instance_double(Vm)]).at_least(:once)
    expect {
      vh.create_addresses
    }.to raise_error RuntimeError, "BUG: failover ip 1.1.1.0/30 is already assigned to a vm"
  end

  it "finds local ip to assign to veth* devices" do
    expect(SecureRandom).to receive(:random_number).with(32767).and_return(5)
    expect(vh.veth_pair_random_ip4_addr.network.to_s).to eq("169.254.0.10")
  end

  it "finds local ip to assign to veth* devices and eliminates already assigned" do
    expect(vh).to receive(:vms).and_return([instance_double(Vm, local_vetho_ip: "169.254.0.10")]).at_least(:once)
    expect(SecureRandom).to receive(:random_number).with(32767).and_return(5, 10)
    expect(vh.veth_pair_random_ip4_addr.network.to_s).to eq("169.254.0.20")
  end
end
