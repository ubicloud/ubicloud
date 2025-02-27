# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

class MockStringWithExitstatus < String
  attr_accessor :exitstatus

  def initialize(str, exitstatus = 0)
    super(str)
    self.exitstatus = exitstatus
  end
end

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
    expect(SecureRandom).to receive(:random_number).and_return(0)
    expect(SecureRandom).to receive(:random_number).and_call_original
    expect(vh.ip6_random_vm_network.to_s).not_to eq(vh.ip6_reserved_network)
  end

  it "can generate ipv6 for hosts with smaller than /64 prefix with two bytes" do
    vh.net6 = NetAddr.parse_net("2a01:4f9:2b:35a::/68")
    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(5)
    expect(vh.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:0:4000:0:0/83")

    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2)
    expect(vh.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:0:2000:0:0/83")

    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**16 - 1)
    expect(vh.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:fff:e000::/83")
  end

  it "can generate the mask properly" do
    vh.net6 = NetAddr.parse_net("::/64")
    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(5001)
    expect(vh.ip6_random_vm_network.to_s).to eq("::1388:0:0:0/79")
    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2)
    expect(vh.ip6_random_vm_network.to_s).to eq("::2:0:0:0/79")
    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**16 - 1)
    expect(vh.ip6_random_vm_network.to_s).to eq("::fffe:0:0:0/79")
    expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**15)
    expect(vh.ip6_random_vm_network.to_s).to eq("::8000:0:0:0/79")
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
      expect(args[:stack]).to eq([subject_id: vh.id, image_name: "my-image", custom_url: "https://example.com/my-image.raw", version: "20230303"])
    end
    vh.download_boot_image("my-image", custom_url: "https://example.com/my-image.raw", version: "20230303")
  end

  it "has a shortcut to download a new firmware for x64" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    vh.arch = "x64"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("DownloadFirmware")
      expect(args[:stack]).to eq([subject_id: vh.id, version: "202405", sha256: "sha-1"])
    end
    vh.download_firmware(version_x64: "202405", sha256_x64: "sha-1")
  end

  it "has a shortcut to download a new firmware for arm64" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    vh.arch = "arm64"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("DownloadFirmware")
      expect(args[:stack]).to eq([subject_id: vh.id, version: "202406", sha256: "sha-2"])
    end
    vh.download_firmware(version_arm64: "202406", sha256_arm64: "sha-2")
  end

  it "requires version and sha256 to download a new firmware" do
    vh.arch = "x64"
    expect { vh.download_firmware(sha256_x64: "thesha") }.to raise_error(ArgumentError, "No version provided")
    expect { vh.download_firmware(version_x64: "202405") }.to raise_error(ArgumentError, "No SHA-256 digest provided")
    vh.arch = "arm64"
    expect { vh.download_firmware(sha256_arm64: "thesha") }.to raise_error(ArgumentError, "No version provided")
    expect { vh.download_firmware(version_arm64: "202406") }.to raise_error(ArgumentError, "No SHA-256 digest provided")
  end

  it "has a shortcut to download a new version of cloud hypervisor for x64" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    vh.arch = "x64"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("DownloadCloudHypervisor")
      expect(args[:stack]).to eq([subject_id: vh.id, version: "35.1", sha256_ch_bin: "sha-1", sha256_ch_remote: "sha-2"])
    end
    vh.download_cloud_hypervisor(version_x64: "35.1", sha256_ch_bin_x64: "sha-1", sha256_ch_remote_x64: "sha-2")
  end

  it "has a shortcut to download a new version of cloud hypervisor for arm64" do
    vh.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
    vh.arch = "arm64"
    expect(Strand).to receive(:create) do |args|
      expect(args[:prog]).to eq("DownloadCloudHypervisor")
      expect(args[:stack]).to eq([subject_id: vh.id, version: "35.1", sha256_ch_bin: "sha-3", sha256_ch_remote: "sha-4"])
    end
    vh.download_cloud_hypervisor(version_arm64: "35.1", sha256_ch_bin_arm64: "sha-3", sha256_ch_remote_arm64: "sha-4")
  end

  it "requires version to download a new version of cloud hypervisor" do
    vh.arch = "x64"
    expect { vh.download_cloud_hypervisor(sha256_ch_bin_x64: "ch_sha", sha256_ch_remote_x64: "remote_sha") }.to raise_error(ArgumentError, "No version provided")
    vh.arch = "arm64"
    expect { vh.download_cloud_hypervisor(sha256_ch_bin_arm64: "ch_sha", sha256_ch_remote_arm64: "remote_sha") }.to raise_error(ArgumentError, "No version provided")
    vh.arch = "unexpectedarch"
    expect { vh.download_cloud_hypervisor(version_x64: "35.1", version_arm64: "35.1") }.to raise_error("BUG: unexpected architecture")
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
    expect(address.assigned_vm_addresses).to receive(:count).and_return(4)
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

  context "when provider is leaseweb" do
    before do
      allow(vh).to receive(:provider).and_return("leaseweb")
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

    it "finds another address if it's the very first ip" do
      expect(vh).to receive(:assigned_subnets).and_return([address]).at_least(:once)
      expect(vh).to receive(:sshable).and_return(instance_double(Sshable, host: "0.0.0.2")).at_least(:once)
      expect(SecureRandom).to receive(:random_number).with(4).and_return(0, 1)
      ip4, r_address = vh.ip4_random_vm_network
      expect(ip4.to_s).to eq("0.0.0.1")
      expect(r_address).to eq(address)
    end

    it "finds another address if it's the very last ip" do
      expect(vh).to receive(:assigned_subnets).and_return([address]).at_least(:once)
      expect(vh).to receive(:sshable).and_return(instance_double(Sshable, host: "0.0.0.1")).at_least(:once)
      expect(SecureRandom).to receive(:random_number).with(4).and_return(3, 2)
      ip4, r_address = vh.ip4_random_vm_network
      expect(ip4.to_s).to eq("0.0.0.2")
      expect(r_address).to eq(address)
    end
  end

  it "sshable_address returns the sshable address" do
    expect(vh).to receive(:assigned_host_addresses).and_return([assigned_host_address])
    expect(vh.sshable_address).to eq(assigned_host_address)
  end

  it "hetznerifies a host" do
    expect(vh).to receive(:create_addresses).at_least(:once)
    expect(HostProvider).to receive(:create).with(server_identifier: "12", provider_name: HostProvider::HETZNER_PROVIDER_NAME).and_return(true)

    vh.hetznerify("12")
  end

  it "reimage server fails for non development" do
    expect(Config).to receive(:development?).and_return(false)
    expect {
      vh.reimage
    }.to raise_error(RuntimeError, "BUG: reimage is only allowed in development")
  end

  it "reimages the server in development" do
    expect(Config).to receive(:development?).and_return(true)
    expect(Hosting::Apis).to receive(:reimage_server).with(vh)
    vh.reimage
  end

  it "hardware resets the server" do
    expect(Hosting::Apis).to receive(:hardware_reset_server).with(vh)
    vh.hardware_reset
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

    expect(adr).to receive(:assigned_vm_addresses).and_return([instance_double(Vm)]).at_least(:once)
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

  it "initiates a new health monitor session" do
    sshable = instance_double(Sshable)
    expect(vh).to receive(:sshable).and_return(sshable)
    expect(sshable).to receive(:start_fresh_session)
    vh.init_health_monitor_session
  end

  it "returns disk device ids when StorageDevice has unix_device_list" do
    sd = StorageDevice.create_with_id(vm_host_id: vh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["wwn-random-id1", "wwn-random-id2"])
    allow(vh).to receive(:storage_devices).and_return([sd])
    expect(vh.disk_device_ids).to eq(["wwn-random-id1", "wwn-random-id2"])
  end

  it "returns disk device names" do
    sd = StorageDevice.create_with_id(vm_host_id: vh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["wwn-random-id1", "wwn-random-id2"])
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    allow(vh).to receive(:storage_devices).and_return([sd])

    expect(session[:ssh_session]).to receive(:exec!).with("readlink -f /dev/disk/by-id/wwn-random-id1").and_return("sda")
    expect(session[:ssh_session]).to receive(:exec!).with("readlink -f /dev/disk/by-id/wwn-random-id2").and_return("sdb")

    expect(vh.disk_device_names(session[:ssh_session])).to eq(["sda", "sdb"])
  end

  it "converts disk devices when StorageDevice has unix_device_list with the old formatting for SSD disks" do
    sd = StorageDevice.create_with_id(vm_host_id: vh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["sda"])
    sshable = instance_double(Sshable)
    expect(sd).to receive(:vm_host).and_return(vh)
    expect(sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sda$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-random-id1")
    expect(vh).to receive(:sshable).and_return(sshable)
    allow(vh).to receive(:storage_devices).and_return([sd])
    expect(vh.disk_device_ids).to eq(["wwn-random-id1"])
  end

  it "converts disk devices when StorageDevice has unix_device_list with the old formatting for NVMe disks" do
    sd = StorageDevice.create_with_id(vm_host_id: vh.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["nvme0n1"])
    sshable = instance_double(Sshable)
    expect(sd).to receive(:vm_host).and_return(vh)
    expect(sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme0n1$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id")
    expect(vh).to receive(:sshable).and_return(sshable)
    allow(vh).to receive(:storage_devices).and_return([sd])
    expect(vh.disk_device_ids).to eq(["nvme-eui.random-id"])
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    allow(vh).to receive(:disk_device_names).and_return(["sda"])
    allow(session[:ssh_session]).to receive(:exec!).with("sudo smartctl -j -H /dev/sda -d scsi | jq .smart_status.passed").and_return(MockStringWithExitstatus.new("true\n", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("lsblk --json").and_return(MockStringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sudo bash -c \"head -c 1M </dev/zero > /test-file\"").and_return(MockStringWithExitstatus.new("", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sha256sum /test-file").and_return(MockStringWithExitstatus.new("30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58  /test-file\n", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sudo rm /test-file").and_return(MockStringWithExitstatus.new("", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("journalctl -kS -1min --no-pager").and_return(MockStringWithExitstatus.new("random ok logs", 0))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")

    expect(session[:ssh_session]).to receive(:exec!).and_raise Sshable::SshError
    expect(vh).to receive(:reload).and_return(vh)
    expect(vh).to receive(:incr_checkup)
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse on a non-default mountpoint with kernel errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["sda"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    expect(vh).to receive(:check_storage_read_write).and_return(true)
    allow(session[:ssh_session]).to receive(:exec!).with("journalctl -kS -1min --no-pager").and_return(MockStringWithExitstatus.new("Nov 04 12:18:04 ubuntu kernel: Buffer I/O error on dev sda, logical block 1032, lost async page write", 0))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse on a with read/write errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["sda"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    expect(session[:ssh_session]).to receive(:exec!).with("lsblk --json").and_return(MockStringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
    expect(session[:ssh_session]).to receive(:exec!).with("sudo bash -c \"head -c 1M </dev/zero > /test-file\"").and_return(MockStringWithExitstatus.new("failed to write file", 1))
    expect(session[:ssh_session]).to receive(:exec!).with("sha256sum /test-file").and_return(MockStringWithExitstatus.new("30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58  /test-file\n", 0))
    expect(session[:ssh_session]).to receive(:exec!).with("sudo rm /test-file").and_return(MockStringWithExitstatus.new("could not remove file", 1))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse with kernel errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["sda"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    expect(vh).to receive(:check_storage_nvme).and_return(true)
    expect(vh).to receive(:check_storage_read_write).and_return(true)
    allow(session[:ssh_session]).to receive(:exec!).with("journalctl -kS -1min --no-pager").and_return(MockStringWithExitstatus.new("exit code 1", 1))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse with smartctl errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["nvme0n1"])

    allow(session[:ssh_session]).to receive(:exec!).with("sudo smartctl -j -H /dev/nvme0n1 | jq .smart_status.passed").and_return(MockStringWithExitstatus.new("false\n", 0))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse with nvme errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["nvme0n1"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    allow(session[:ssh_session]).to receive(:exec!).with("sudo nvme smart-log /dev/nvme0n1 | grep \"critical_warning\" | awk '{print $3}'").and_return(MockStringWithExitstatus.new("1\n", 0))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "checks pulse with no nvme errors" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["nvme0n1"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    allow(session[:ssh_session]).to receive(:exec!).with("sudo nvme smart-log /dev/nvme0n1 | grep \"critical_warning\" | awk '{print $3}'").and_return(MockStringWithExitstatus.new("0\n", 0))
    expect(vh).to receive(:check_storage_read_write).and_return(true)
    expect(vh).to receive(:check_storage_kernel_logs).and_return(true)
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")
  end

  it "checks pulse on a non-default mountpoint with faulty read/write on disk" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }
    allow(vh).to receive(:disk_device_names).and_return(["sda"])

    expect(vh).to receive(:check_storage_smartctl).and_return(true)
    expect(vh).to receive(:check_storage_nvme).and_return(true)
    allow(session[:ssh_session]).to receive(:exec!).with("lsblk --json").and_return(MockStringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/random-mountpoint"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sudo bash -c \"head -c 1M </dev/zero > /random-mountpoint/test-file\"").and_return(MockStringWithExitstatus.new("", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sha256sum /random-mountpoint/test-file").and_return(MockStringWithExitstatus.new("wrong-hash  /test-file\n", 0))
    allow(session[:ssh_session]).to receive(:exec!).with("sudo rm /random-mountpoint/test-file").and_return(MockStringWithExitstatus.new("", 0))
    expect(vh.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  it "#render_arch errors on an unexpected architecture" do
    expect(vh).to receive(:arch).and_return("nope")
    expect { vh.render_arch(arm64: "a", x64: "x") }.to raise_error RuntimeError, "BUG: inexhaustive render code"
  end

  describe "#spdk_cpu_count" do
    it "uses 2 cpus for AX161" do
      expect(vh).to receive(:total_cpus).and_return(64)
      expect(vh.spdk_cpu_count).to eq(2)
    end

    it "uses 4 cpus for RX220" do
      expect(vh).to receive(:total_cpus).and_return(80)
      expect(vh.spdk_cpu_count).to eq(4)
    end

    it "uses 4 cpus for AX162" do
      expect(vh).to receive(:total_cpus).and_return(96)
      expect(vh.spdk_cpu_count).to eq(4)
    end
  end

  describe "#allow_slices" do
    it "allows slices" do
      expect(vh).to receive(:update).with(accepts_slices: true)
      vh.allow_slices
    end
  end

  describe "#disallow_slices" do
    it "disallows slices" do
      expect(vh).to receive(:update).with(accepts_slices: false)
      vh.disallow_slices
    end
  end

  describe "#provider_name" do
    it "returns the provider name" do
      expect(vh).to receive(:provider).and_return(instance_double(HostProvider, provider_name: "hetzner"))
      expect(vh.provider_name).to eq("hetzner")
    end

    it "returns nil if there is no provider" do
      expect(vh).to receive(:provider).and_return(nil)
      expect(vh.provider_name).to be_nil
    end
  end
end
