# frozen_string_literal: true

require_relative "../lib/vm_setup"
require "openssl"
require "base64"

RSpec.describe VmSetup do
  mock_vm_path = Class.new(VmPath) do
    attr_reader :writes
    def initialize(vm_name)
      super
      @writes = {}
    end

    def write(path, s)
      s += "\n" unless s.end_with?("\n")
      @writes[File.basename(path)] = s
    end
  end

  subject(:vs) {
    Class.new(described_class) do
      def no_valid_ch_version
        nil
      end

      def no_valid_firmware_version
        nil
      end
    end.new("test")
  }

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
    let(:vps) { mock_vm_path.new("test") }

    before { allow(vs).to receive(:vp).and_return(vps) }

    def written_user_data
      vps.writes["user-data"]
    end

    def parse_user_data
      raw = written_user_data
      expect(raw).to start_with("#cloud-config\n")
      YAML.safe_load(raw)
    end

    it "generates valid cloud-config with no swap" do
      vs.write_user_data("some_user", ["some_ssh_key"], nil, "")
      expect(written_user_data).to eq <<~'YAML'
        #cloud-config
        users:
        - name: some_user
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: "/bin/bash"
          ssh_authorized_keys:
          - some_ssh_key
        ssh_pwauth: false
        runcmd:
        - systemctl daemon-reload
        bootcmd:
        - nft add table ip6 filter
        - nft add chain ip6 filter output \{ type filter hook output priority 0 \; \}
        - nft add rule ip6 filter output ip6 daddr fd00:0b1c:100d:5AFE::/64 meta skuid \!\= 0 tcp flags syn reject with tcp reset
      YAML
    end

    it "generates valid cloud-config with swap" do
      vs.write_user_data("some_user", ["some_ssh_key"], 123, "")
      config = parse_user_data
      expect(config["swap"]).to eq({"filename" => "/swapfile", "size" => 123})
      expect(written_user_data).to include("swap:\n  filename: \"/swapfile\"\n  size: 123\n")
    end

    it "fails if the swap is not an integer" do
      expect {
        vs.write_user_data("some_user", ["some_ssh_key"], "123", "")
      }.to raise_error RuntimeError, "BUG: swap_size_bytes must be an integer"
    end

    it "includes install commands for debian boot images" do
      vs.write_user_data("user", ["key"], nil, "debian-12")
      config = parse_user_data
      expect(config["runcmd"]).to include("apt-get update")
      expect(config["runcmd"]).to include("apt-get install -y nftables")
    end

    it "includes install commands for almalinux boot images" do
      vs.write_user_data("user", ["key"], nil, "almalinux-9")
      config = parse_user_data
      expect(config["runcmd"]).to include("dnf install -y nftables")
    end

    it "includes no install commands for ubuntu boot images" do
      vs.write_user_data("user", ["key"], nil, "ubuntu-noble")
      config = parse_user_data
      expect(config["runcmd"]).to eq(["systemctl daemon-reload"])
    end

    it "includes init_script as a string in runcmd" do
      vs.write_user_data("user", ["key"], nil, "", init_script: "#!/bin/bash\necho hello")
      config = parse_user_data
      expect(config["runcmd"].last).to eq("#!/bin/bash\necho hello")
    end

    it "safely handles YAML-special usernames" do
      vs.write_user_data("NO", ["key"], nil, "")
      config = parse_user_data
      expect(config["users"].first["name"]).to eq("NO")
    end

    it "handles multiple SSH keys" do
      keys = ["ssh-ed25519 AAAAC3Nz... user@host", "ssh-rsa AAAAB3Nz... other@host"]
      vs.write_user_data("user", keys, nil, "")
      config = parse_user_data
      expect(config["users"].first["ssh_authorized_keys"]).to eq(keys)
    end

    it "handles empty public keys" do
      vs.write_user_data("user", [], nil, "")
      config = parse_user_data
      expect(config["users"].first["ssh_authorized_keys"]).to eq([])
    end

    %w[yes no true false null ~].each do |special_name|
      it "preserves YAML-special username #{special_name.inspect} as a string" do
        vs.write_user_data(special_name, ["key"], nil, "")
        config = parse_user_data
        expect(config["users"].first["name"]).to eq(special_name)
        expect(config["users"].first["name"]).to be_a(String)
      end
    end

    it "preserves SSH key with spaces in comment" do
      key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ John Doe's key"
      vs.write_user_data("user", [key], nil, "")
      config = parse_user_data
      expect(config["users"].first["ssh_authorized_keys"]).to eq([key])
    end

    it "preserves SSH key with no comment" do
      key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtestkeywithnocomment"
      vs.write_user_data("user", [key], nil, "")
      config = parse_user_data
      expect(config["users"].first["ssh_authorized_keys"]).to eq([key])
    end

    it "does not line-wrap a long RSA 4096 key" do
      long_key = "ssh-rsa " + "A" * 700 + " user@host"
      vs.write_user_data("user", [long_key], nil, "")
      expect(written_user_data).to include(long_key)
      config = parse_user_data
      expect(config["users"].first["ssh_authorized_keys"]).to eq([long_key])
    end

    it "preserves init script with YAML special characters" do
      script = "key: value\n- list item\n# comment line"
      vs.write_user_data("user", ["key"], nil, "", init_script: script)
      config = parse_user_data
      expect(config["runcmd"].last).to eq(script)
    end

    it "preserves init script with shell metacharacters" do
      script = "echo 'hello \"world\"' && exit 0"
      vs.write_user_data("user", ["key"], nil, "", init_script: script)
      config = parse_user_data
      expect(config["runcmd"].last).to eq(script)
    end

    it "preserves multi-line init script as a single string" do
      script = "#!/bin/bash\nset -euo pipefail\necho hello\nexit 0"
      vs.write_user_data("user", ["key"], nil, "", init_script: script)
      config = parse_user_data
      expect(config["runcmd"].last).to eq(script)
      expect(config["runcmd"].last).to be_a(String)
    end

    it "stores swap size as an integer, not a string" do
      vs.write_user_data("user", ["key"], 1073741824, "")
      config = parse_user_data
      expect(config["swap"]["size"]).to eq(1073741824)
      expect(config["swap"]["size"]).to be_a(Integer)
    end
  end

  describe "#cloudinit" do
    let(:vps) { mock_vm_path.new("test") }
    let(:nics) { [VmSetup::Nic.new("fd48:666c:a296:ce4b:2cc6::/79", "192.168.5.50/32", "nctest", "3e:bd:a5:96:f7:b9", "10.0.0.254/32")] }

    before do
      allow(vs).to receive(:vp).and_return(vps)
      allow(vs).to receive(:write_user_data)
      allow(vs).to receive(:r)
      allow(FileUtils).to receive(:rm_rf)
      allow(FileUtils).to receive(:chmod)
      allow(FileUtils).to receive(:chown)
    end

    it "generates valid YAML meta-data with instance-id and local-hostname" do
      vs.cloudinit("user", ["key"], "fddf:53d2:4c89:2305:46a0::/79", nics, nil, "ubuntu-noble", "10.0.0.2", ipv6_disabled: false)
      expect(vps.writes["meta-data"]).to eq <<~YAML
        ---
        instance-id: test
        local-hostname: test
      YAML
    end

    it "generates valid YAML network-config with ethernets" do
      vs.cloudinit("user", ["key"], "fddf:53d2:4c89:2305:46a0::/79", nics, nil, "ubuntu-noble", "10.0.0.2", ipv6_disabled: false)
      expect(vps.writes["network-config"]).to eq <<~YAML
        ---
        version: 2
        ethernets:
          enx3ebda596f7b9:
            match:
              macaddress: "3e:bd:a5:96:f7:b9"
            dhcp6: true
            dhcp4: true
      YAML
    end

    it "quotes MAC addresses that YAML 1.1 would parse as sexagesimal" do
      sexagesimal_nics = [VmSetup::Nic.new("fd48:666c:a296:ce4b:2cc6::/79", "192.168.5.50/32", "nctest", "12:40:37:27:57:41", "10.0.0.254/32")]
      vs.cloudinit("user", ["key"], "fddf:53d2:4c89:2305:46a0::/79", sexagesimal_nics, nil, "ubuntu-noble", "10.0.0.2", ipv6_disabled: false)
      raw_yaml = vps.writes["network-config"]
      expect(raw_yaml).to include('macaddress: "12:40:37:27:57:41"')
      config = YAML.safe_load(raw_yaml)
      expect(config["ethernets"]["enx124037275741"]["match"]["macaddress"]).to eq("12:40:37:27:57:41")
      expect(config["ethernets"]["enx124037275741"]["match"]["macaddress"]).to be_a(String)
    end

    it "generates network-config with multiple NICs" do
      multi_nics = [
        VmSetup::Nic.new("fd48:666c:a296:ce4b:2cc6::/79", "192.168.5.50/32", "nctest1", "3e:bd:a5:96:f7:b9", "10.0.0.254/32"),
        VmSetup::Nic.new("fddf:53d2:4c89:2305:46a0::/79", "10.10.10.10/32", "nctest2", "fb:55:dd:ba:21:0a", "10.0.0.253/32")
      ]
      vs.cloudinit("user", ["key"], "fddf:53d2:4c89:2305:46a0::/79", multi_nics, nil, "ubuntu-noble", "10.0.0.2", ipv6_disabled: false)
      config = YAML.safe_load(vps.writes["network-config"])
      expect(config["ethernets"].keys).to contain_exactly("enx3ebda596f7b9", "enxfb55ddba210a")
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
      expect(VmSetupFscrypt).to receive(:lock).with("test")
      expect(vs).to receive(:r).with("deluser --remove-home test")
      expect(VmSetupFscrypt).to receive(:purge).with("test")
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
      expect(vs).to receive(:prepare_gpus).with([], nil)
      expect(vs).to receive(:start_systemd_unit)
      expect(vs).to receive(:enable_bursting).with("some_slice.slice", 200)
      expect(vs).to receive(:update_via_routes)

      vs.recreate_unpersisted(
        "gua", "ip4", "local_ip4", "nics", 4, false, "storage_params", "storage_secrets",
        "10.0.0.2", [], "some_slice.slice", 200, nil, multiqueue: true
      )
    end

    it "can create unpersisted state without bursting" do
      expect(vs).to receive(:setup_networking).with(true, "gua", "ip4", "local_ip4", "nics", false, "10.0.0.2", multiqueue: true)
      expect(vs).to receive(:hugepages).with(4)
      expect(vs).to receive(:storage).with("storage_params", "storage_secrets", false)
      expect(vs).to receive(:prepare_gpus).with(["dev"], 1)
      expect(vs).to receive(:start_systemd_unit)
      expect(vs).to receive(:update_via_routes)

      vs.recreate_unpersisted(
        "gua", "ip4", "local_ip4", "nics", 4, false, "storage_params", "storage_secrets",
        "10.0.0.2", ["dev"], "system.slice", 0, 1, multiqueue: true
      )
    end
  end

  describe "#install_systemd_unit" do
    let(:args) { [2, "1:1:1:2", 2, [], [VmSetup::Nic.new("fd00::/64", "10.0.0.1/32", "tap0", "02:aa:bb:cc:dd:01", "10.0.0.254/32")], [], "system.slice", 0] }

    it "uses cloud-hypervisor by default" do
      vps = instance_spy(VmPath)
      allow(vs).to receive(:vp).and_return(vps)
      expect(vs).to receive(:build_ch_service).and_return("CH_SERVICE")
      expect(vs).to receive(:r).with("systemctl daemon-reload")

      vs.send(:install_systemd_unit, *args)

      expect(vps).to have_received(:write_systemd_service).with("CH_SERVICE")
    end

    it "uses QEMU when requested" do
      vs.instance_variable_set(:@hypervisor, "qemu")

      vps = instance_spy(VmPath)
      allow(vs).to receive(:vp).and_return(vps)
      expect(vs).to receive(:build_qemu_service).and_return("QEMU_SERVICE")
      expect(vs).to receive(:r).with("systemctl daemon-reload")

      vs.send(:install_systemd_unit, *args)

      expect(vps).to have_received(:write_systemd_service).with("QEMU_SERVICE")
    end

    it "can write a cloud-hypervisor systemd unit" do
      vps = instance_spy(VmPath,
        ch_api_sock: "/tmp/ch.sock",
        serial_log: "/vm/test/serial.log",
        cloudinit_img: "/vm/test/cloudinit.img")
      allow(vs).to receive(:vp).and_return(vps)

      vs.instance_variable_set(:@ch_version,
        CloudHypervisor::Version.new("35.1", "sha256_ch_bin", "sha256_ch_remote"))

      vs.instance_variable_set(:@firmware_version,
        CloudHypervisor::Firmware.new("202311", "sha256"))

      expect(vs).to receive(:r).with("systemctl daemon-reload")
      vs.send(:install_systemd_unit, *args)

      expect(vps).to have_received(:write_systemd_service) { |content|
        expect(content).to include("[Service]")
        expect(content).to include("Slice=system.slice")
        expect(content).to include("NetworkNamespacePath=/var/run/netns/test")

        expect(content).to include("ExecStart=/opt/cloud-hypervisor/v35.1/cloud-hypervisor -v")
        %w[
          --api-socket path=/tmp/ch.sock \
          --kernel /opt/fw/CLOUDHV-202311.fd \
          --disk path=/vm/test/cloudinit.img \
          --console off --serial file=/vm/test/serial.log \
          --cpus boot=2,topology=1:1:1:2 \
          --memory size=2G,hugepages=on,hugepage_size=1G \
          --net mac=02:aa:bb:cc:dd:01,tap=tap0,ip=,mask=,num_queues=5
        ].each { |frag| expect(content).to include(frag) }

        expect(content).to include("ExecStop=/opt/cloud-hypervisor/v35.1/ch-remote --api-socket /tmp/ch.sock shutdown-vmm")
        expect(content).to include("Restart=no")
        expect(content).to include("User=test")
        expect(content).to include("Group=test")
        expect(content).to include("LimitNOFILE=500000")
      }
    end

    it "can write a QEMU systemd unit" do
      vs.instance_variable_set(:@hypervisor, "qemu")

      vps = instance_spy(VmPath,
        serial_log: "/vm/test/serial.log",
        cloudinit_img: "/vm/test/cloudinit.img")
      allow(vs).to receive(:vp).and_return(vps)

      vs.instance_variable_set(:@firmware_version,
        CloudHypervisor::Firmware.new("202311", "sha256"))

      expect(vs).to receive(:r).with("systemctl daemon-reload")
      expect(vs).to receive(:cpu_vendor).and_return("GenuineIntel")
      vs.send(:install_systemd_unit, *args)

      expect(vps).to have_received(:write_systemd_service) { |content|
        expect(content).to include("[Service]")
        expect(content).to include("Slice=system.slice")
        expect(content).to include("NetworkNamespacePath=/var/run/netns/test")

        expect(content).to include("ExecStart=qemu-system-#{Arch.render(x64: "x86_64", arm64: "aarch64")}")
        %w[
          -bios /opt/fw/QEMU.fd
          -object memory-backend-memfd,id=mem0,size=2G,hugetlb=on,hugetlbsize=1G,prealloc=on,share=on
          -numa node,memdev=mem0
          -m 2G
          -smp cpus=2,maxcpus=2,threads=1,cores=1,dies=1,sockets=2
          -cpu host
          -enable-kvm
          -machine accel=kvm,type=q35
          -drive if=none,file=/vm/test/cloudinit.img,format=raw,readonly=on,id=cidrive
          -device virtio-blk-pci,drive=cidrive,romfile=
          -netdev tap,id=net0,ifname=tap0,script=no,downscript=no,queues=5,vhost=on
          -device virtio-net-pci,mac=02:aa:bb:cc:dd:01,netdev=net0,mq=on,romfile=
          -serial file:/vm/test/serial.log
          -display none
          -vga none
        ].each { |frag| expect(content).to include(frag) }

        expect(content).to include("KillSignal=SIGTERM")
        expect(content).to include("TimeoutStopSec=30s")
        expect(content).to include("Restart=no")
        expect(content).to include("User=test")
        expect(content).to include("Group=test")
        expect(content).to include("LimitNOFILE=500000")
      }
    end

    it "adds topoext when CPU vendor is AMD" do
      vs.instance_variable_set(:@hypervisor, "qemu")

      vps = instance_spy(VmPath,
        serial_log: "/vm/test/serial.log",
        cloudinit_img: "/vm/test/cloudinit.img")
      allow(vs).to receive(:vp).and_return(vps)

      vs.instance_variable_set(:@firmware_version,
        CloudHypervisor::Firmware.new("202311", "sha256"))

      expect(vs).to receive(:r).with("systemctl daemon-reload")
      expect(vs).to receive(:cpu_vendor).and_return("AuthenticAMD")

      vs.send(:install_systemd_unit, *args)

      expect(vps).to have_received(:write_systemd_service) { |content|
        expect(content).to include("-cpu host,topoext=on")
        expect(content).not_to include("-cpu host\n")
      }
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
