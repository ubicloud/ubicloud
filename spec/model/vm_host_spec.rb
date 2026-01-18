# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe VmHost do
  subject(:vm_host) {
    described_class.new_with_id(
      net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
      ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2")
    )
  }

  let(:cidr) { NetAddr::IPv4Net.parse("0.0.0.0/30") }
  let(:address) {
    Address.new(
      cidr:,
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
      ["1.1.1.12/32", "1.1.0.0", true],
      ["1.1.1.13/32", "1.1.1.1", false],
      ["2a01:4f8:10a:128b::/64", "1.1.1.1", true]
    ].map {
      Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
    }
  }

  describe "#ip6_random_vm_network" do
    it "can generate random ipv6 subnets" do
      expect(vm_host.ip6_random_vm_network.contains(vm_host.ip6)).to be false
    end

    it "tries to get another random network if the proposal matches the reserved nework" do
      vm_host.id = nil
      expect(SecureRandom).to receive(:random_number).and_return(0)
      expect(SecureRandom).to receive(:random_number).and_call_original
      expect(vm_host.ip6_random_vm_network.to_s).not_to eq(vm_host.ip6_reserved_network)
    end

    it "can generate ipv6 for hosts with smaller than /64 prefix with two bytes" do
      vm_host.net6 = NetAddr.parse_net("2a01:4f9:2b:35a::/68")
      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(5)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:0:4000:0:0/83")

      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:0:2000:0:0/83")

      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**16 - 1)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("2a01:4f9:2b:35a:fff:e000::/83")
    end

    it "can generate the mask properly" do
      vm_host.net6 = NetAddr.parse_net("::/64")
      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(5001)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("::1388:0:0:0/79")
      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("::2:0:0:0/79")
      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**16 - 1)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("::fffe:0:0:0/79")
      expect(SecureRandom).to receive(:random_number).with(2...2**16).and_return(2**15)
      expect(vm_host.ip6_random_vm_network.to_s).to eq("::8000:0:0:0/79")
    end

    it "returns nil if there is no ip6 address" do
      vm_host.net6 = nil
      expect(vm_host.ip6_random_vm_network).to be_nil
    end
  end

  describe "#ip6_reserved_network" do
    it "crashes if the prefix length for a VM is shorter than the host's prefix" do
      expect {
        vm_host.ip6_reserved_network(1)
      }.to raise_error RuntimeError, "BUG: host prefix must be is shorter than reserved prefix"
    end

    it "has no ipv6 reserved network when vendor used NDP" do
      expect(vm_host).to receive(:ip6).and_return(nil)
      expect(vm_host.ip6_reserved_network).to be_nil
    end
  end

  describe "#install_rhizome" do
    it "has a shortcut to install Rhizome" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("InstallRhizome")
        expect(args[:stack]).to eq([subject_id: vm_host.id, target_folder: "host", install_specs: false])
      end
      vm_host.install_rhizome
    end
  end

  describe "#download_boot_image" do
    it "has a shortcut to download a new boot image" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("DownloadBootImage")
        expect(args[:stack]).to eq([subject_id: vm_host.id, image_name: "my-image", custom_url: "https://example.com/my-image.raw", version: "20230303", download_r2: true])
      end
      vm_host.download_boot_image("my-image", custom_url: "https://example.com/my-image.raw", version: "20230303")
    end
  end

  describe "#download_firmware" do
    it "has a shortcut to download a new firmware for x64" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      vm_host.arch = "x64"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("DownloadFirmware")
        expect(args[:stack]).to eq([subject_id: vm_host.id, version: "202405", sha256: "sha-1"])
      end
      vm_host.download_firmware(version_x64: "202405", sha256_x64: "sha-1")
    end

    it "has a shortcut to download a new firmware for arm64" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      vm_host.arch = "arm64"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("DownloadFirmware")
        expect(args[:stack]).to eq([subject_id: vm_host.id, version: "202406", sha256: "sha-2"])
      end
      vm_host.download_firmware(version_arm64: "202406", sha256_arm64: "sha-2")
    end

    it "requires version and sha256 to download a new firmware" do
      vm_host.arch = "x64"
      expect { vm_host.download_firmware(sha256_x64: "thesha") }.to raise_error(ArgumentError, "No version provided")
      expect { vm_host.download_firmware(version_x64: "202405") }.to raise_error(ArgumentError, "No SHA-256 digest provided")
      vm_host.arch = "arm64"
      expect { vm_host.download_firmware(sha256_arm64: "thesha") }.to raise_error(ArgumentError, "No version provided")
      expect { vm_host.download_firmware(version_arm64: "202406") }.to raise_error(ArgumentError, "No SHA-256 digest provided")
    end
  end

  describe "#download_cloud_hypervisor" do
    it "has a shortcut to download a new version of cloud hypervisor for x64" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      vm_host.arch = "x64"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("DownloadCloudHypervisor")
        expect(args[:stack]).to eq([subject_id: vm_host.id, version: "35.1", sha256_ch_bin: "sha-1", sha256_ch_remote: "sha-2"])
      end
      vm_host.download_cloud_hypervisor(version_x64: "35.1", sha256_ch_bin_x64: "sha-1", sha256_ch_remote_x64: "sha-2")
    end

    it "has a shortcut to download a new version of cloud hypervisor for arm64" do
      vm_host.id = "46683a25-acb1-4371-afe9-d39f303e44b4"
      vm_host.arch = "arm64"
      expect(Strand).to receive(:create) do |args|
        expect(args[:prog]).to eq("DownloadCloudHypervisor")
        expect(args[:stack]).to eq([subject_id: vm_host.id, version: "35.1", sha256_ch_bin: "sha-3", sha256_ch_remote: "sha-4"])
      end
      vm_host.download_cloud_hypervisor(version_arm64: "35.1", sha256_ch_bin_arm64: "sha-3", sha256_ch_remote_arm64: "sha-4")
    end

    it "requires version to download a new version of cloud hypervisor" do
      vm_host.arch = "x64"
      expect { vm_host.download_cloud_hypervisor(sha256_ch_bin_x64: "ch_sha", sha256_ch_remote_x64: "remote_sha") }.to raise_error(ArgumentError, "No version provided")
      vm_host.arch = "arm64"
      expect { vm_host.download_cloud_hypervisor(sha256_ch_bin_arm64: "ch_sha", sha256_ch_remote_arm64: "remote_sha") }.to raise_error(ArgumentError, "No version provided")
      vm_host.arch = "unexpectedarch"
      expect { vm_host.download_cloud_hypervisor(version_x64: "35.1", version_arm64: "35.1") }.to raise_error("BUG: unexpected architecture")
    end
  end

  describe "#ip4_random_vm_network" do
    it "returns nil if there is no available subnet" do
      ip4, address = vm_host.ip4_random_vm_network
      expect(ip4).to be_nil
      expect(address).to be_nil
    end

    it "returns an unused ip address if there is one" do
      vm_host = Prog::Vm::HostNexus.assemble("127.0.0.1").subject
      address_id = Address.create(vm_host:, cidr: "128.0.0.0/30").id
      ips = %w[128.0.0.0 128.0.0.1 128.0.0.2 128.0.0.3]

      4.times do
        ip4, r_address = vm_host.ip4_random_vm_network
        expect(r_address).to be_a Address
        expect(r_address.id).to eq address_id
        expect(ips).to include ip4.to_s

        project_id = Project.create(name: "test").id
        vm = Prog::Vm::Nexus.assemble("a a", project_id, force_host_id: vm_host.id)
        AssignedVmAddress.create(address_id:, dst_vm_id: vm.id, ip: ips.shift)
      end

      expect(Clog).not_to receive(:emit)
      expect(vm_host.ip4_random_vm_network).to eq [nil, nil]
    end
  end

  describe "#sshable_address" do
    it "returns the sshable address" do
      vm_host = Prog::Vm::HostNexus.assemble("128.0.0.1").subject
      expect(vm_host.sshable_address.ip.network.to_s).to eq("128.0.0.1")
    end
  end

  describe "#reimage" do
    it "fails for non development" do
      expect(Config).to receive(:development?).and_return(false)
      expect {
        vm_host.reimage
      }.to raise_error(RuntimeError, "BUG: reimage is only allowed in development")
    end

    it "reimages the server in development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(Hosting::Apis).to receive(:reimage_server).with(vm_host)
      vm_host.reimage
    end
  end

  describe "#hardware_reset" do
    it "hardware resets the server" do
      expect(Hosting::Apis).to receive(:hardware_reset_server).with(vm_host)
      vm_host.hardware_reset
    end
  end

  describe "#create_addresses" do
    it "fails if a failover ip of non existent server is being added" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(vm_host).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
      Sshable.create_with_id(vm_host, host: "test.localhost")
      described_class.create_with_id(vm_host, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      expect(vm_host).to receive(:assigned_subnets).and_return([]).at_least(:once)
      expect { vm_host.create_addresses }.to raise_error(RuntimeError, "BUG: source host 1.1.1.1 isn't added to the database")
    end

    it "creates given addresses and doesn't make an api call when ips given" do
      expect(vm_host).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
      Sshable.create_with_id(vm_host, host: "1.1.0.0")
      Sshable.create(host: "1.1.1.1")

      described_class.create_with_id(vm_host, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      expect(vm_host).to receive(:assigned_subnets).and_return([]).at_least(:once)
      vm_host.create_addresses(ip_records: hetzner_ips)

      expect(Address.where(routed_to_host_id: vm_host.id).count).to eq(4)
    end

    it "creates addresses" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(vm_host).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
      Sshable.create_with_id(vm_host, host: "1.1.0.0")
      Sshable.create(host: "1.1.1.1")

      described_class.create_with_id(vm_host, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      expect(vm_host).to receive(:assigned_subnets).and_return([]).at_least(:once)
      vm_host.create_addresses

      expect(Address.where(routed_to_host_id: vm_host.id).count).to eq(4)
    end

    it "returns immediately if there are no addresses to create" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(nil)
      vm_host.create_addresses
      expect(Address.where(routed_to_host_id: vm_host.id).count).to eq(0)
    end

    it "skips already assigned subnets" do
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)
      expect(vm_host).to receive(:id).and_return("46683a25-acb1-4371-afe9-d39f303e44b4").at_least(:once)
      Sshable.create_with_id(vm_host, host: "1.1.0.0")
      Sshable.create(host: "1.1.1.1")
      described_class.create_with_id(vm_host, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      expect(vm_host).to receive(:assigned_subnets).and_return([Address.new(cidr: NetAddr::IPv4Net.parse("1.1.1.0/30"))]).at_least(:once)
      vm_host.create_addresses
      expect(Address.where(routed_to_host_id: vm_host.id).count).to eq(3)
    end

    it "updates the routed_to_host_id if the address is reassigned to another host and there is no vm using the ip range" do
      hetzner_ips = [
        Hosting::HetznerApis::IpInfo.new(ip_address: "1.1.1.0/30", source_host_ip: "1.1.1.1", is_failover: true)
      ]
      old_id = "4c5dc171-a116-4a05-9e6d-381a4b382b71"
      new_id = "46683a25-acb1-4371-afe9-d39f303e44b4"

      expect(vm_host).to receive(:id).and_return(new_id).at_least(:once)
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)

      Sshable.create_with_id(old_id, host: "1.1.0.0")
      described_class.create_with_id(old_id, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      Sshable.create(host: "1.1.1.1")
      adr = Address.create(cidr: "1.1.1.0/30", routed_to_host_id: old_id)
      expect(Address).to receive(:where).with(cidr: "1.1.1.0/30").and_return([adr]).once

      expect(adr).to receive(:update).with(routed_to_host_id: new_id).and_return(true)
      vm_host.create_addresses
    end

    it "fails if the ip range is already assigned to a vm" do
      hetzner_ips = [
        Hosting::HetznerApis::IpInfo.new(ip_address: "1.1.1.0/30", source_host_ip: "1.1.1.1", is_failover: true)
      ]
      old_id = "4c5dc171-a116-4a05-9e6d-381a4b382b71"
      expect(Hosting::Apis).to receive(:pull_ips).and_return(hetzner_ips)

      Sshable.create_with_id(old_id, host: "1.1.0.0")
      old_vm_host = described_class.create_with_id(old_id, location_id: Location::HETZNER_FSN1_ID, family: "standard")

      adr = Address.create(cidr: "1.1.1.0/30", routed_to_host_id: old_id)

      # Create a real VM and AssignedVmAddress to make the address already assigned
      project = Project.create(name: "test-project")
      vm = Prog::Vm::Nexus.assemble("a a", project.id, force_host_id: old_vm_host.id).subject
      AssignedVmAddress.create(address_id: adr.id, dst_vm_id: vm.id, ip: "1.1.1.1/32")

      expect {
        vm_host.create_addresses
      }.to raise_error RuntimeError, "BUG: failover ip 1.1.1.0/30 is already assigned to a vm"
    end
  end

  describe "#veth_pair_random_ip4_addr" do
    it "finds local ip to assign to veth* devices and eliminates already assigned" do
      vm_host = Prog::Vm::HostNexus.assemble("127.0.0.1").subject
      project_id = Project.create(name: "test").id
      vm = Prog::Vm::Nexus.assemble("a a", project_id, force_host_id: vm_host.id).subject

      expect(SecureRandom).to receive(:random_number).with(32767 - 1024).and_return(5, 5)
      expect(vm_host.veth_pair_random_ip4_addr.network.to_s).to eq("169.254.0.10")
      vm.update(local_vetho_ip: "169.254.0.10", vm_host_id: vm_host.id)
      expect(vm_host.veth_pair_random_ip4_addr.network.to_s).to eq("169.254.0.12")
    end
  end

  describe "#init_health_monitor_session" do
    it "initiates a new health monitor session" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vh_with_sshable = described_class.create_with_id(sshable, location_id: Location::HETZNER_FSN1_ID, family: "standard",
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2"))
      expect(vh_with_sshable.sshable).to receive(:start_fresh_session)
      vh_with_sshable.init_health_monitor_session
    end
  end

  describe "#init_metrics_export_session" do
    it "initiates a new health monitor session for metrics exporter" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vh_with_sshable = described_class.create_with_id(sshable, location_id: Location::HETZNER_FSN1_ID, family: "standard",
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2"))
      expect(vh_with_sshable.sshable).to receive(:start_fresh_session)
      vh_with_sshable.init_metrics_export_session
    end
  end

  describe "#disk_device_ids" do
    it "returns disk device ids when StorageDevice has unix_device_list" do
      sd = StorageDevice.create(name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["wwn-random-id1", "wwn-random-id2"])
      allow(vm_host).to receive(:storage_devices).and_return([sd])
      expect(vm_host.disk_device_ids).to eq(["wwn-random-id1", "wwn-random-id2"])
    end

    it "converts disk devices when StorageDevice has unix_device_list with the old formatting for SSD disks" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vh_with_sshable = described_class.create_with_id(sshable, location_id: Location::HETZNER_FSN1_ID, family: "standard",
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2"))
      StorageDevice.create(name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["sda"], vm_host_id: vh_with_sshable.id)

      expect(vh_with_sshable.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sda\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-random-id1")
      expect(vh_with_sshable.disk_device_ids).to eq(["wwn-random-id1"])
    end

    it "converts disk devices when StorageDevice has unix_device_list with the old formatting for NVMe disks" do
      sshable = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vh_with_sshable = described_class.create_with_id(sshable, location_id: Location::HETZNER_FSN1_ID, family: "standard",
        net6: NetAddr.parse_net("2a01:4f9:2b:35a::/64"),
        ip6: NetAddr.parse_ip("2a01:4f9:2b:35a::2"))
      StorageDevice.create(name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["nvme0n1"], vm_host_id: vh_with_sshable.id)

      expect(vh_with_sshable.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme0n1\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id")
      expect(vh_with_sshable.disk_device_ids).to eq(["nvme-eui.random-id"])
    end
  end

  describe "#disk_device_names" do
    it "returns disk device names" do
      sd = StorageDevice.create(name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["wwn-random-id1", "wwn-random-id2"])
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      allow(vm_host).to receive(:storage_devices).and_return([sd])

      expect(session[:ssh_session]).to receive(:_exec!).with("readlink -f /dev/disk/by-id/wwn-random-id1").and_return("sda")
      expect(session[:ssh_session]).to receive(:_exec!).with("readlink -f /dev/disk/by-id/wwn-random-id2").and_return("sdb")

      expect(vm_host.disk_device_names(session[:ssh_session])).to eq(["sda", "sdb"])
    end
  end

  describe "#check_pulse" do
    it "checks pulse" do
      host = create_vm_host
      Strand.create_with_id(host, prog: "Prog::Vm::HostNexus", label: "wait")
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }

      allow(host).to receive(:disk_device_names).and_return(["sda"])
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo smartctl -j -H /dev/sda -d scsi | jq .smart_status.passed").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("true\n", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("lsblk --json").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
      file_path = "/test-file-monitor"
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo bash -c head\\ -c\\ 1M\\ \\</dev/zero\\ \\>\\ #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("sha256sum #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58  #{file_path}\n", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo rm #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("journalctl -kS -1min --no-pager").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("random ok logs", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("cat /sys/devices/system/clocksource/clocksource0/available_clocksource").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("tsc hpet acpi_pm \n", 0))
      expect(host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")

      expect(session[:ssh_session]).to receive(:_exec!).and_raise Sshable::SshError
      expect(host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
      expect(Semaphore.where(strand_id: host.id, name: "checkup").count).to eq(1)
    end

    it "checks pulse on a non-default mountpoint with kernel errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["sda"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      expect(vm_host).to receive(:check_storage_read_write).and_return(true)
      allow(session[:ssh_session]).to receive(:_exec!).with("journalctl -kS -1min --no-pager").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("Nov 04 12:18:04 ubuntu kernel: Buffer I/O error on dev sda, logical block 1032, lost async page write", 0))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "checks pulse on a with read/write errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["sda"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      expect(session[:ssh_session]).to receive(:_exec!).with("lsblk --json").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
      file_path = "/test-file-monitor"
      expect(session[:ssh_session]).to receive(:_exec!).with("sudo bash -c head\\ -c\\ 1M\\ \\</dev/zero\\ \\>\\ #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("failed to write file", 1))
      expect(session[:ssh_session]).to receive(:_exec!).with("sha256sum #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58  #{file_path}\n", 0))
      expect(session[:ssh_session]).to receive(:_exec!).with("sudo rm #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("could not remove file", 1))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "checks pulse with kernel errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["sda"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      expect(vm_host).to receive(:check_storage_nvme).and_return(true)
      expect(vm_host).to receive(:check_storage_read_write).and_return(true)
      allow(session[:ssh_session]).to receive(:_exec!).with("journalctl -kS -1min --no-pager").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("exit code 1", 1))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "checks pulse with smartctl errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["nvme0n1"])

      allow(session[:ssh_session]).to receive(:_exec!).with("sudo smartctl -j -H /dev/nvme0n1 | jq .smart_status.passed").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("false\n", 0))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "checks pulse with nvme errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["nvme0n1"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo nvme smart-log /dev/nvme0n1 | grep \"critical_warning\" | awk '{print $3}'").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("1\n", 0))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "checks pulse with no nvme errors" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["nvme0n1"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo nvme smart-log /dev/nvme0n1 | grep \"critical_warning\" | awk '{print $3}'").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("0\n", 0))
      expect(vm_host).to receive(:check_storage_read_write).and_return(true)
      expect(vm_host).to receive(:check_storage_kernel_logs).and_return(true)
      expect(vm_host).to receive(:check_clock_source).and_return(true)
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "checks pulse on a non-default mountpoint with faulty read/write on disk" do
      session = {
        ssh_session: Net::SSH::Connection::Session.allocate
      }
      pulse = {
        reading: "up",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      allow(vm_host).to receive(:disk_device_names).and_return(["sda"])

      expect(vm_host).to receive(:check_storage_smartctl).and_return(true)
      expect(vm_host).to receive(:check_storage_nvme).and_return(true)
      allow(session[:ssh_session]).to receive(:_exec!).with("lsblk --json").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new('{"blockdevices": [{"name": "fd0","maj:min": "2:0","rm": true,"size": "4K","ro": false,"type": "disk","mountpoints": [null]},{"name": "sda","maj:min": "8:0","rm": false,"size": "2.2G","ro": false,"type": "disk","mountpoints": [null],"children": [{"name": "sda1","maj:min": "8:1","rm": false,"size": "2.1G","ro": false,"type": "part","mountpoints": ["/random-mountpoint"]},{"name": "sda14","maj:min": "8:14","rm": false,"size": "4M","ro": false,"type": "part","mountpoints": [null]}]}]}', 0))
      file_path = "/random-mountpoint/test-file-monitor"
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo bash -c head\\ -c\\ 1M\\ \\</dev/zero\\ \\>\\ #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("sha256sum #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("wrong-hash  /test-file\n", 0))
      allow(session[:ssh_session]).to receive(:_exec!).with("sudo rm #{file_path}").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))
      expect(vm_host.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
      it "reraises the exception for exception class: #{ex.class}" do
        session = {ssh_session: Net::SSH::Connection::Session.allocate}
        expect(vm_host).to receive(:perform_health_checks).and_raise(ex)
        expect { vm_host.check_pulse(session:, previous_pulse: "notnil") }.to raise_error(ex)
      end
    end
  end

  describe "#render_arch" do
    it "errors on an unexpected architecture" do
      expect(vm_host).to receive(:arch).and_return("nope")
      expect { vm_host.render_arch(arm64: "a", x64: "x") }.to raise_error RuntimeError, "BUG: inexhaustive render code"
    end
  end

  describe "#check_clock_source" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    it "succeeds if arm64 machine uses arch_sys_counter" do
      vm_host.arch = "arm64"
      expect(session).to receive(:_exec!).with("cat /sys/devices/system/clocksource/clocksource0/available_clocksource").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("arch_sys_counter", 0))
      expect(vm_host.check_clock_source(session)).to be true
    end

    it "succeeds if it uses tsc" do
      expect(session).to receive(:_exec!).with("cat /sys/devices/system/clocksource/clocksource0/available_clocksource").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("tsc hpet acpi_pm \n", 0))
      expect(vm_host.check_clock_source(session)).to be true
    end

    it "fails if it uses hpet" do
      expect(session).to receive(:_exec!).with("cat /sys/devices/system/clocksource/clocksource0/available_clocksource").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("hpet acpi_pm \n", 0))
      expect(Clog).to receive(:emit).with("unexpected clock source", Hash).and_call_original
      expect(vm_host.check_clock_source(session)).to be false
    end
  end

  describe "#check_last_boot_id" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    it "raises if command execution exits with non-zero status code" do
      expect(session).to receive(:_exec!).with("cat /proc/sys/kernel/random/boot_id").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("it didn't work", 1))
      expect { vm_host.check_last_boot_id(session) }.to raise_error(RuntimeError, "Failed to exec on session: it didn't work")
    end

    it "does nothing if boot_id matches" do
      expect(session).to receive(:_exec!).with("cat /proc/sys/kernel/random/boot_id").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("boot-id", 0))
      expect(vm_host).to receive(:last_boot_id).and_return("boot-id")
      expect { vm_host.check_last_boot_id(session) }.not_to raise_error
    end

    it "assembles a page for it" do
      expect(session).to receive(:_exec!).with("cat /proc/sys/kernel/random/boot_id").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("another-boot-id", 0))
      expect(vm_host).to receive(:last_boot_id).and_return("boot-id")
      vm_host.check_last_boot_id(session)
      expect(Page.first.summary).to eq("Recorded last_boot_id of #{vm_host.ubid} in database differs from the actual boot_id")
    end
  end

  describe "#spdk_cpu_count" do
    it "uses 2 cpus for AX161" do
      expect(vm_host).to receive(:total_cpus).and_return(64)
      expect(vm_host.spdk_cpu_count).to eq(2)
    end

    it "uses 4 cpus for RX220" do
      expect(vm_host).to receive(:total_cpus).and_return(80)
      expect(vm_host.spdk_cpu_count).to eq(4)
    end

    it "uses 4 cpus for AX162" do
      expect(vm_host).to receive(:total_cpus).and_return(96)
      expect(vm_host.spdk_cpu_count).to eq(4)
    end
  end

  describe "#allow_slices" do
    it "allows slices" do
      expect(vm_host).to receive(:update).with(accepts_slices: true)
      vm_host.allow_slices
    end
  end

  describe "#disallow_slices" do
    it "disallows slices" do
      expect(vm_host).to receive(:update).with(accepts_slices: false)
      vm_host.disallow_slices
    end
  end

  describe "#provider_name" do
    it "returns the provider name" do
      sa = Sshable.create(host: "provider-test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vm_host = described_class.create_with_id(sa, location_id: Location::HETZNER_FSN1_ID, family: "standard")
      HostProvider.create do |hp|
        hp.id = vm_host.id
        hp.server_identifier = "test-server-123"
        hp.provider_name = "hetzner"
      end
      expect(vm_host.provider_name).to eq("hetzner")
    end

    it "returns nil if there is no provider" do
      sa = Sshable.create(host: "no-provider.localhost", raw_private_key_1: SshKey.generate.keypair)
      vm_host = described_class.create_with_id(sa, location_id: Location::HETZNER_FSN1_ID, family: "standard")
      expect(vm_host.provider_name).to be_nil
    end
  end

  describe "#metrics_config" do
    it "returns the right metrics config" do
      sa = Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair)
      vh = described_class.create_with_id(sa, location_id: Location::HETZNER_FSN1_ID, family: "standard")
      expect(Config).to receive(:monitoring_service_project_id).and_return("d272dc1f-52ba-4e52-9bcc-f90dce42a226")
      expect(vm_host.metrics_config).to eq({
        endpoints: [
          "http://localhost:9100/metrics"
        ],
        max_file_retention: 120,
        interval: "15s",
        additional_labels: {ubicloud_resource_id: vm_host.ubid},
        metrics_dir: "/home/rhizome/host/metrics",
        project_id: "d272dc1f-52ba-4e52-9bcc-f90dce42a226"
      })
    end
  end
end
