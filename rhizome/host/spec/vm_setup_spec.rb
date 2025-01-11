# frozen_string_literal: true

require_relative "../lib/vm_setup"
require "openssl"
require "base64"

RSpec.describe VmSetup do
  subject(:vs) { described_class.new("test") }

  def key_wrapping_secrets
    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    {
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "algorithm" => key_wrapping_algorithm,
      "auth_data" => "Ubicloud-Test-Auth"
    }
  end

  it "can halve an IPv6 network" do
    lower, upper = vs.subdivide_network(NetAddr.parse_net("2a01:4f9:2b:35b:7e40::/79"))
    expect(lower.to_s).to eq("2a01:4f9:2b:35b:7e40::/80")
    expect(upper.to_s).to eq("2a01:4f9:2b:35b:7e41::/80")
  end

  it "can enable cpu.max.burst on a slice's cgroup" do
    expect(File).to receive(:write).with("/sys/fs/cgroup/test.slice/test.service/cpu.max.burst", "42000")
    vs.enable_bursting("test.slice", 42)
  end

  describe "#write_user_data" do
    let(:vps) { instance_spy(VmPath) }

    before { expect(vs).to receive(:vp).and_return(vps).at_least(:once) }

    it "templates user YAML with no swap" do
      vs.write_user_data("some_user", ["some_ssh_key"], nil, "")
      expect(vps).to have_received(:write_user_data) {
        expect(_1).to match(/some_user/)
        expect(_1).to match(/some_ssh_key/)
      }
    end

    it "templates user YAML with swap" do
      vs.write_user_data("some_user", ["some_ssh_key"], 123, "")
      expect(vps).to have_received(:write_user_data) {
        expect(_1).to match(/some_user/)
        expect(_1).to match(/some_ssh_key/)
        expect(_1).to match(/size: 123/)
      }
    end

    it "fails if the swap is not an integer" do
      expect {
        vs.write_user_data("some_user", ["some_ssh_key"], "123", "")
      }.to raise_error RuntimeError, "BUG: swap_size_bytes must be an integer"
    end
  end

  describe "#purge_storage" do
    let(:vol_1_params) {
      {
        "size_gib" => 20,
        "device_id" => "test_0",
        "disk_index" => 0,
        "encrypted" => false,
        "spdk_version" => "some-version"
      }
    }
    let(:vol_2_params) {
      {
        "size_gib" => 20,
        "device_id" => "test_1",
        "disk_index" => 1,
        "encrypted" => true,
        "spdk_version" => "some-version"
      }
    }
    let(:vol_3_params) {
      {
        "size_gib" => 0,
        "device_id" => "test_2",
        "disk_index" => 2,
        "encrypted" => false,
        "read_only" => true
      }
    }
    let(:params) {
      JSON.generate({storage_volumes: [vol_1_params, vol_2_params, vol_3_params]})
    }

    it "can purge storage" do
      expect(File).to receive(:exist?).with("/vm/test/prep.json").and_return(true)
      expect(File).to receive(:read).with("/vm/test/prep.json").and_return(params)

      # delete the unencrypted volume
      sv_1 = instance_double(StorageVolume)
      expect(StorageVolume).to receive(:new).with("test", vol_1_params).and_return(sv_1)
      expect(sv_1).to receive(:purge_spdk_artifacts)
      expect(sv_1).to receive(:storage_root).and_return("/var/storage/test")

      # delete the encrypted volume
      sv_2 = instance_double(StorageVolume)
      expect(StorageVolume).to receive(:new).with("test", vol_2_params).and_return(sv_2)
      expect(sv_2).to receive(:purge_spdk_artifacts)
      expect(sv_2).to receive(:storage_root).and_return("/var/storage/test")

      vs.purge_storage
    end

    it "exits silently if vm hasn't been created yet" do
      expect(File).to receive(:exist?).with("/vm/test/prep.json").and_return(false)
      expect { vs.purge_storage }.not_to raise_error
    end
  end

  describe "#purge" do
    it "can purge" do
      expect(vs).to receive(:r).with("ip netns del test")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test.service")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test-dnsmasq.service")
      expect(vs).to receive(:r).with("systemctl daemon-reload")
      expect(vs).to receive(:purge_storage)
      expect(vs).to receive(:unmount_hugepages)
      expect(vs).to receive(:r).with("deluser --remove-home test")
      expect(IO).to receive(:popen).with(["systemd-escape", "test.service"]).and_return("test.service")
      expect(vs).to receive(:block_ip4)

      vs.purge
    end
  end

  describe "#unmount_hugepages" do
    it "can unmount hugepages" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages")
      vs.unmount_hugepages
    end

    it "exits silently if hugepages isn't mounted" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages").and_raise(CommandFail.new("", "", "/vm/test/hugepages: no mount point specified."))
      vs.unmount_hugepages
    end

    it "fails if umount fails with an unexpected error" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages").and_raise(CommandFail.new("", "", "/vm/test/hugepages: wait, what?"))
      expect { vs.unmount_hugepages }.to raise_error CommandFail
    end
  end

  describe "#recreate_unpersisted" do
    it "can recreate unpersisted state" do
      expect(vs).to receive(:setup_networking).with(true, "gua", "ip4", "local_ip4", "nics", false, "10.0.0.2", multiqueue: true)
      expect(vs).to receive(:hugepages).with(4)
      expect(vs).to receive(:storage).with("storage_params", "storage_secrets", false)
      expect(vs).to receive(:prepare_pci_devices).with([])
      expect(vs).to receive(:start_systemd_unit)
      expect(vs).to receive(:enable_bursting).with("some_slice.slice", 200)
      expect(vs).to receive(:update_via_routes)

      vs.recreate_unpersisted(
        "gua", "ip4", "local_ip4", "nics", 4, false, "storage_params", "storage_secrets",
        "10.0.0.2", [], "some_slice.slice", 200, multiqueue: true
      )
    end

    it "can create unpersisted state without bursting" do
      expect(vs).to receive(:setup_networking).with(true, "gua", "ip4", "local_ip4", "nics", false, "10.0.0.2", multiqueue: true)
      expect(vs).to receive(:hugepages).with(4)
      expect(vs).to receive(:storage).with("storage_params", "storage_secrets", false)
      expect(vs).to receive(:prepare_pci_devices).with([])
      expect(vs).to receive(:start_systemd_unit)
      expect(vs).to receive(:update_via_routes)

      vs.recreate_unpersisted(
        "gua", "ip4", "local_ip4", "nics", 4, false, "storage_params", "storage_secrets",
        "10.0.0.2", [], "system.slice", 0, multiqueue: true
      )
    end
  end

  describe "#restart" do
    it "can restart a VM" do
      expect(vs).to receive(:restart_systemd_unit)
      expect(vs).to receive(:enable_bursting).with("some_slice.slice", 50)

      vs.restart("some_slice.slice", 50)
    end
  end

  describe "#storage" do
    let(:storage_params) {
      [
        {"boot" => true, "size_gib" => 20, "device_id" => "test_0", "disk_index" => 0, "encrypted" => false},
        {"boot" => false, "size_gib" => 20, "device_id" => "test_1", "disk_index" => 1, "encrypted" => true},
        {"boot" => false, "size_gib" => 0, "device_id" => "test_2", "disk_index" => 0, "encrypted" => false, "read_only" => true}
      ]
    }
    let(:storage_secrets) {
      {
        "test_1" => "storage_secrets"
      }
    }
    let(:storage_volumes) {
      v1 = instance_double(StorageVolume)
      v2 = instance_double(StorageVolume)
      allow(v1).to receive_messages(vhost_sock: "/var/storage/vhost/vhost.1", spdk_service: "spdk.service")
      allow(v2).to receive_messages(vhost_sock: "/var/storage/vhost/vhost.2", spdk_service: "spdk.service")
      [v1, v2]
    }

    before do
      expect(StorageVolume).to receive(:new).with("test", storage_params[0]).and_return(storage_volumes[0])
      expect(StorageVolume).to receive(:new).with("test", storage_params[1]).and_return(storage_volumes[1])
    end

    it "can setup storage (prep)" do
      expect(storage_volumes[0]).to receive(:start).with(nil)
      expect(storage_volumes[0]).to receive(:prep).with(nil)
      expect(storage_volumes[1]).to receive(:start).with(storage_secrets["test_1"])
      expect(storage_volumes[1]).to receive(:prep).with(storage_secrets["test_1"])

      vs.storage(storage_params, storage_secrets, true)
    end

    it "can setup storage (no prep)" do
      expect(storage_volumes[0]).to receive(:start).with(nil)
      expect(storage_volumes[1]).to receive(:start).with(storage_secrets["test_1"])

      vs.storage(storage_params, storage_secrets, false)
    end
  end

  describe "#setup_networking" do
    it "can setup networking" do
      vps = instance_spy(VmPath)
      expect(vs).to receive(:vp).and_return(vps).at_least(:once)

      gua = "fddf:53d2:4c89:2305:46a0::"
      guest_ephemeral = NetAddr.parse_net("fddf:53d2:4c89:2305::/65")
      clover_ephemeral = NetAddr.parse_net("fddf:53d2:4c89:2305:8000::/65")
      ip4 = "192.168.1.100"

      expect(vs).to receive(:unblock_ip4).with("192.168.1.100")
      expect(vs).to receive(:interfaces).with([], true)
      expect(vs).to receive(:setup_veths_6) {
        expect(_1.to_s).to eq(guest_ephemeral.to_s)
        expect(_2.to_s).to eq(clover_ephemeral.to_s)
        expect(_3).to eq(gua)
        expect(_4).to be(false)
      }
      expect(vs).to receive(:setup_taps_6).with(gua, [], "10.0.0.2")
      expect(vs).to receive(:routes4).with(ip4, "local_ip4", [])
      expect(vs).to receive(:write_nftables_conf).with(ip4, gua, [])
      expect(vs).to receive(:forwarding)

      expect(vps).to receive(:write_guest_ephemeral).with(guest_ephemeral.to_s)
      expect(vps).to receive(:write_clover_ephemeral).with(clover_ephemeral.to_s)

      vs.setup_networking(false, gua, ip4, "local_ip4", [], false, "10.0.0.2", multiqueue: true)
    end

    it "can setup networking for empty ip4" do
      gua = "fddf:53d2:4c89:2305:46a0::"
      expect(vs).to receive(:interfaces).with([], false)
      expect(vs).to receive(:setup_veths_6)
      expect(vs).to receive(:setup_taps_6).with(gua, [], "10.0.0.2")
      expect(vs).to receive(:routes4).with(nil, "local_ip4", [])
      expect(vs).to receive(:forwarding)
      expect(vs).to receive(:write_nftables_conf)

      vs.setup_networking(true, gua, "", "local_ip4", [], false, "10.0.0.2", multiqueue: false)
    end

    it "can generate nftables config" do
      vps = instance_spy(VmPath)
      expect(vs).to receive(:vp).and_return(vps).at_least(:once)

      gua = "fddf:53d2:4c89:2305:46a0::/79"
      ip4 = "123.123.123.123"
      nics = [
        %w[fd48:666c:a296:ce4b:2cc6::/79 192.168.5.50/32 ncaka58xyg 3e:bd:a5:96:f7:b9],
        %w[fddf:53d2:4c89:2305:46a0::/79 10.10.10.10/32 ncbbbbbbbb fb:55:dd:ba:21:0a]
      ].map { VmSetup::Nic.new(*_1) }

      expect(vps).to receive(:write_nftables_conf).with(<<NFTABLES_CONF)
table ip raw {
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    # allow dhcp
    udp sport 68 udp dport 67 accept
    udp sport 67 udp dport 68 accept

    # avoid ip4 spoofing
    ether saddr {3e:bd:a5:96:f7:b9, fb:55:dd:ba:21:0a} ip saddr != {192.168.5.50/32, 10.10.10.10/32, 123.123.123.123} drop
  }
  chain postrouting {
    type filter hook postrouting priority raw; policy accept;
    # avoid dhcp ports to be used for spoofing
    oifname vethitest udp sport { 67, 68 } udp dport { 67, 68 } drop
  }
}
table ip6 raw {
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    # avoid ip6 spoofing
    ether saddr 3e:bd:a5:96:f7:b9 ip6 saddr != {fddf:53d2:4c89:2305:46a0::/80,fd48:666c:a296:ce4b:2cc6::/79,fe80::3cbd:a5ff:fe96:f7b9} drop
    ether saddr fb:55:dd:ba:21:0a ip6 saddr != fddf:53d2:4c89:2305:46a0::/79 drop
  }
}

table ip6 nat_metadata_endpoint {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip6 daddr FD00:0B1C:100D:5AFE:CE:: tcp dport 80 dnat to [FD00:0B1C:100D:5AFE:CE::]:8080
  }
}

# NAT4 rules
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 123.123.123.123 dnat to 192.168.5.50
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 192.168.5.50 ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to 123.123.123.123
    ip saddr 192.168.5.50 ip daddr 192.168.5.50 snat to 123.123.123.123
  }
}

table inet fw_table {
  chain forward_ingress {
    type filter hook forward priority filter; policy drop;
    ip saddr 0.0.0.0/0 tcp dport 22 ip daddr 192.168.5.50/32 ct state established,related,new counter accept
    ip saddr 192.168.5.50/32 tcp sport 22 ct state established,related counter accept
  }
}
NFTABLES_CONF
      expect(vs).to receive(:apply_nftables)
      vs.write_nftables_conf(ip4, gua, nics)
    end
  end

  describe "#hugepages" do
    it "can setup hugepages" do
      expect(FileUtils).to receive(:mkdir_p).with("/vm/test/hugepages")
      expect(FileUtils).to receive(:chown).with("test", "test", "/vm/test/hugepages")
      expect(vs).to receive(:r).with("mount -t hugetlbfs -o uid=test,size=2G nodev /vm/test/hugepages")
      vs.hugepages(2)
    end
  end

  describe "#start_systemd_unit" do
    it "can start systemd unit" do
      expect(vs).to receive(:r).with("systemctl start test")
      vs.start_systemd_unit
    end
  end

  describe "#restart_systemd_unit" do
    it "can restart systemd unit" do
      expect(vs).to receive(:r).with("systemctl restart test")
      vs.restart_systemd_unit
    end
  end

  describe "#unblock_ip4" do
    it "can unblock ip4" do
      f = instance_double(File)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/etc/nftables.d/test.conf.tmp")
      end.and_yield(f)

      expect(f).to receive(:flock).with(File::LOCK_EX | File::LOCK_NB)
      expect(f).to receive(:puts).with(<<NFTABLES_CONF)
#!/usr/sbin/nft -f
add element inet drop_unused_ip_packets allowed_ipv4_addresses { 1.1.1.1 }
NFTABLES_CONF
      expect(File).to receive(:rename).with("/etc/nftables.d/test.conf.tmp", "/etc/nftables.d/test.conf")

      expect(vs).to receive(:r).with("systemctl reload nftables")

      vs.unblock_ip4("1.1.1.1/32")
    end
  end

  describe "#block_ip4" do
    it "can block ip4" do
      expect(FileUtils).to receive(:rm_f).with("/etc/nftables.d/test.conf")
      expect(vs).to receive(:r).with("systemctl reload nftables")

      vs.block_ip4
    end
  end

  describe "#interfaces" do
    it "can setup interfaces without multiqueue" do
      expect(vs).to receive(:r).with("ip netns del test")
      expect(File).to receive(:exist?).with("/sys/class/net/vethotest").and_return(true, false)
      expect(vs).to receive(:sleep).with(0.1).once

      expect(vs).to receive(:r).with("ip netns add test")
      expect(vs).to receive(:gen_mac).and_return("00:00:00:00:00:00").at_least(:once)
      expect(vs).to receive(:r).with("ip link add vethotest addr 00:00:00:00:00:00 type veth peer name vethitest addr 00:00:00:00:00:00 netns test")
      nics = [VmSetup::Nic.new(nil, nil, "nctest", nil, "1.1.1.1")]
      expect(vs).to receive(:r).with("ip -n test tuntap add dev nctest mode tap user test  ")
      expect(vs).to receive(:r).with("ip -n test addr replace 1.1.1.1 dev nctest")
      vs.interfaces(nics, false)
    end

    it "can setup interfaces with multiqueue" do
      expect(vs).to receive(:r).with("ip netns del test")
      expect(File).to receive(:exist?).with("/sys/class/net/vethotest").and_return(false)

      expect(vs).to receive(:r).with("ip netns add test")
      expect(vs).to receive(:gen_mac).and_return("00:00:00:00:00:00").at_least(:once)
      expect(vs).to receive(:r).with("ip link add vethotest addr 00:00:00:00:00:00 type veth peer name vethitest addr 00:00:00:00:00:00 netns test")
      nics = [VmSetup::Nic.new(nil, nil, "nctest", nil, "1.1.1.1")]
      expect(vs).to receive(:r).with("ip -n test tuntap add dev nctest mode tap user test  multi_queue vnet_hdr ")
      expect(vs).to receive(:r).with("ip -n test addr replace 1.1.1.1 dev nctest")
      vs.interfaces(nics, true)
    end

    it "fails if network namespace can not be deleted" do
      expect(vs).to receive(:r).with("ip netns del test").and_raise(CommandFail.new("", "", "error"))
      expect { vs.interfaces([VmSetup::Nic.new(nil, nil, "nctest", nil, "1.1.1.1")], false) }.to raise_error(CommandFail)
    end
  end
end
