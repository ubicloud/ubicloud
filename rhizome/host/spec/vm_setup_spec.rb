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

  it "templates user YAML" do
    vps = instance_spy(VmPath)
    expect(vs).to receive(:vp).and_return(vps).at_least(:once)
    vs.write_user_data("some_user", "some_ssh_key")
    expect(vps).to have_received(:write_user_data) {
      expect(_1).to match(/some_user/)
      expect(_1).to match(/some_ssh_key/)
    }
  end

  describe "#download_boot_image" do
    it "can download an image" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy.raw").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/ubuntu-jammy.img.tmp")
      end.and_yield
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect(Arch).to receive(:render).and_return("amd64").at_least(:once)
      expect(vs).to receive(:r).with("curl -f -L10 -o /var/storage/images/ubuntu-jammy.img.tmp https://cloud-images.ubuntu.com/releases/jammy/release-20231010/ubuntu-22.04-server-cloudimg-amd64.img")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /var/storage/images/ubuntu-jammy.img.tmp /var/storage/images/ubuntu-jammy.raw")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/images/ubuntu-jammy.img.tmp")

      vs.download_boot_image("ubuntu-jammy")
    end

    it "can download image with custom URL that has query params using azcopy" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/github-ubuntu-2204.vhd.tmp")
      end.and_yield
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect(vs).to receive(:r).with("which azcopy")
      expect(vs).to receive(:r).with("AZCOPY_CONCURRENCY_VALUE=5 azcopy copy https://images.blob.core.windows.net/images/ubuntu2204.vhd\\?sp\\=r\\&st\\=2023-09-05T22:44:05Z\\&se\\=2023-10-07T06:44:05 /var/storage/images/github-ubuntu-2204.vhd.tmp")
      expect(vs).to receive(:r).with("qemu-img convert -p -f vpc -O raw /var/storage/images/github-ubuntu-2204.vhd.tmp /var/storage/images/github-ubuntu-2204.raw")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/images/github-ubuntu-2204.vhd.tmp")

      vs.download_boot_image("github-ubuntu-2204", custom_url: "https://images.blob.core.windows.net/images/ubuntu2204.vhd?sp=r&st=2023-09-05T22:44:05Z&se=2023-10-07T06:44:05")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/var/storage/images/almalinux-9.1.raw").and_return(true)
      vs.download_boot_image("almalinux-9.1")
    end

    it "fails if custom_url not provided for custom image" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect { vs.download_boot_image("github-ubuntu-2204") }.to raise_error RuntimeError, "Must provide custom_url for github-ubuntu-2204 image"
    end

    it "fails if initial image has unsupported format" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect { vs.download_boot_image("github-ubuntu-2204", custom_url: "https://example.com/ubuntu.iso") }.to raise_error RuntimeError, "Unsupported boot_image format: .iso"
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
    let(:params) {
      JSON.generate({storage_volumes: [vol_1_params, vol_2_params]})
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
      expect(vs).to receive(:setup_networking).with(true, "gua", "ip4", "local_ip4", "nics", false, multiqueue: true)
      expect(vs).to receive(:hugepages).with(4)
      expect(vs).to receive(:storage).with("storage_params", "storage_secrets", false)

      vs.recreate_unpersisted("gua", "ip4", "local_ip4", "nics", 4, false, "storage_params", "storage_secrets", multiqueue: true)
    end
  end

  describe "#storage" do
    let(:storage_params) {
      [
        {"boot" => true, "size_gib" => 20, "device_id" => "test_0", "disk_index" => 0, "encrypted" => false},
        {"boot" => false, "size_gib" => 20, "device_id" => "test_1", "disk_index" => 1, "encrypted" => true}
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

      expect(vs).to receive(:interfaces).with([], true)
      expect(vs).to receive(:setup_veths_6) {
        expect(_1.to_s).to eq(guest_ephemeral.to_s)
        expect(_2.to_s).to eq(clover_ephemeral.to_s)
        expect(_3).to eq(gua)
        expect(_4).to be(false)
      }
      expect(vs).to receive(:setup_taps_6).with(gua, [])
      expect(vs).to receive(:routes4).with(ip4, "local_ip4", [])
      expect(vs).to receive(:write_nftables_conf).with(ip4, gua, [])
      expect(vs).to receive(:forwarding)

      expect(vps).to receive(:write_guest_ephemeral).with(guest_ephemeral.to_s)
      expect(vps).to receive(:write_clover_ephemeral).with(clover_ephemeral.to_s)

      vs.setup_networking(false, gua, ip4, "local_ip4", [], false, multiqueue: true)
    end

    it "can setup networking for empty ip4" do
      gua = "fddf:53d2:4c89:2305:46a0::"
      expect(vs).to receive(:interfaces).with([], false)
      expect(vs).to receive(:setup_veths_6)
      expect(vs).to receive(:setup_taps_6).with(gua, [])
      expect(vs).to receive(:routes4).with(nil, "local_ip4", [])
      expect(vs).to receive(:forwarding)
      expect(vs).to receive(:write_nftables_conf)

      vs.setup_networking(true, gua, "", "local_ip4", [], false, multiqueue: false)
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
end
