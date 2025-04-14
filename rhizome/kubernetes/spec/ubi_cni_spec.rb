# frozen_string_literal: true

require_relative "../lib/ubi_cni"
require "json"

RSpec.describe UbiCNI do
  subject(:ubicni) { described_class.new(input, logger) }

  let(:logger) { Logger.new(IO::NULL) }
  let(:input) { {"ranges" => {"subnet_ipv4" => "192.168.1.0/24", "subnet_ipv6" => "fd00::/64", "subnet_ula_ipv6" => "fc00::/64"}} }

  before do
    allow(ENV).to receive(:[]).and_return(nil)
    allow(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("1234")
    allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("xx")
    allow(ENV).to receive(:[]).with("CNI_NETNS").and_return("/var/run/netns/test-ns")
    allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("eth0")
    allow(ENV).to receive(:[]).with("CNI_ARGS").and_return("xx")
    allow(ENV).to receive(:[]).with("CNI_PATH").and_return("xx")
  end

  describe "#run" do
    describe "#handle_add" do
      let(:input) do
        {
          "ranges" => {
            "subnet_ula_ipv6" => "fd00::/64",
            "subnet_ipv6" => "2001:db8::/64",
            "subnet_ipv4" => "192.168.1.0/24"
          }
        }
      end

      let(:container_ipv6) { IPAddr.new("2001:db8::2") }
      let(:container_ula_ipv6) { IPAddr.new("fd00::2") }
      let(:ipv4_container_ip) { IPAddr.new("192.168.1.100") }
      let(:ipv4_gateway_ip) { IPAddr.new("192.168.1.1") }

      before do
        allow(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("abcdef123456")
        allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("ADD")
        allow(ENV).to receive(:[]).with("CNI_NETNS").and_return("/var/run/netns/testnetns")
        allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("eth0")

        allow(FileUtils).to receive(:mkdir_p)
        allow(File).to receive(:write)

        expect(ubicni).to receive(:gen_mac).and_return("00:11:22:33:44:55")
        expect(ubicni).to receive(:gen_mac).and_return("00:aa:bb:cc:dd:ee")
        allow(ubicni).to receive(:mac_to_ipv6_link_local).with("00:11:22:33:44:55").and_return("fe80::02aa:bbff:fecc:ddee")
        allow(ubicni).to receive(:mac_to_ipv6_link_local).with("00:aa:bb:cc:dd:ee").and_return("fe80::0211:22ff:fe33:4455")

        allow(ubicni).to receive(:find_random_available_ip).and_return(
          container_ipv6, container_ula_ipv6, ipv4_container_ip, ipv4_gateway_ip
        )
      end

      it "sets up networking and assigns IPs correctly" do
        expect(ubicni).to receive(:r).with("ip link add veth_abcdef12 addr 00:aa:bb:cc:dd:ee type veth peer name eth0 addr 00:11:22:33:44:55 netns testnetns").ordered

        expect(ubicni).to receive(:r).with("ip -6 -n testnetns addr replace #{container_ipv6}/#{container_ipv6.prefix} dev eth0").ordered
        expect(ubicni).to receive(:r).with("ip -6 -n testnetns link set eth0 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -6 -n testnetns route replace default via fe80::0211:22ff:fe33:4455 dev eth0").ordered
        expect(ubicni).to receive(:r).with("ip -6 link set veth_abcdef12 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -6 route replace #{container_ipv6}/#{container_ipv6.prefix} via fe80::02aa:bbff:fecc:ddee dev veth_abcdef12 mtu 1400").ordered

        expect(ubicni).to receive(:r).with("ip -6 -n testnetns addr replace #{container_ula_ipv6}/#{container_ula_ipv6.prefix} dev eth0").ordered
        expect(ubicni).to receive(:r).with("ip -6 -n testnetns link set eth0 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -6 link set veth_abcdef12 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -6 route replace #{container_ula_ipv6}/#{container_ula_ipv6.prefix} via fe80::02aa:bbff:fecc:ddee dev veth_abcdef12 mtu 1400").ordered

        expect(ubicni).to receive(:r).with("ip addr replace #{ipv4_gateway_ip}/24 dev veth_abcdef12").ordered
        expect(ubicni).to receive(:r).with("ip link set veth_abcdef12 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -n testnetns addr replace #{ipv4_container_ip}/24 dev eth0").ordered
        expect(ubicni).to receive(:r).with("ip -n testnetns link set eth0 mtu 1400 up").ordered
        expect(ubicni).to receive(:r).with("ip -n testnetns route replace default via #{ipv4_gateway_ip}").ordered
        expect(ubicni).to receive(:r).with("ip route replace #{ipv4_container_ip}/#{ipv4_container_ip.prefix} via #{ipv4_gateway_ip} dev veth_abcdef12").ordered
        expect(ubicni).to receive(:r).with("echo 1 > /proc/sys/net/ipv4/conf/veth_abcdef12/proxy_arp").ordered

        output = ubicni.handle_add
        response = JSON.parse(output)

        expect(response).to include("cniVersion" => "1.0.0")
        expect(response["interfaces"]).to be_an(Array)
        expect(response["interfaces"]).to include(
          hash_including("name" => "eth0", "mac" => "00:11:22:33:44:55")
        )

        expect(response["ips"]).to be_an(Array)
        expect(response["ips"]).to include(
          hash_including("address" => "#{container_ipv6}/128"),
          hash_including("address" => "#{container_ula_ipv6}/128"),
          hash_including("address" => "#{ipv4_container_ip}/32")
        )

        expect(response["routes"]).to be_an(Array)
        expect(response["routes"]).to include(
          hash_including("dst" => "0.0.0.0/0")
        )
      end
    end

    it "calls handle_add if CNI_COMMAND is ADD" do
      allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("ADD")
      expect(ubicni).to receive(:handle_add).and_return(nil)
      ubicni.run
    end

    it "calls handle_del if CNI_COMMAND is DEL" do
      allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("DEL")
      expect(ubicni).to receive(:handle_del).and_return(nil)
      ubicni.run
    end

    it "calls handle_get if CNI_COMMAND is GET" do
      allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("GET")
      expect(ubicni).to receive(:handle_get).and_return(nil)
      ubicni.run
    end

    it "raises an error for an unsupported command" do
      allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("INVALID")
      expect(logger).to receive(:error).with("Unsupported CNI command: INVALID")
      expect { ubicni.run }.to output("{\"code\":100,\"msg\":\"Unsupported CNI command: INVALID\"}\n").to_stdout.and(raise_error(SystemExit))
    end
  end

  describe "#handle_del" do
    it "removes allocated IP when container exists" do
      ubicni.instance_variable_set(:@ipam_store, {"allocated_ips" => {"1234" => ["192.168.1.2"]}})
      expect(File).to receive(:write)
      expect { ubicni.handle_del }.to change { ubicni.instance_variable_get(:@ipam_store)["allocated_ips"].size }.by(-1)
    end

    it "does nothing when container does not exist" do
      ubicni.instance_variable_set(:@ipam_store, {"allocated_ips" => {"12345" => ["192.168.1.2"]}})
      expect(File).not_to receive(:write)
      expect { ubicni.handle_del }.not_to change { ubicni.instance_variable_get(:@ipam_store)["allocated_ips"].size }
    end
  end

  describe "#handle_get" do
    before do
      allow(File).to receive(:read).with("/opt/cni/bin/ubicni-ipam-store").and_return("{}")
      allow(File).to receive(:exist?).with("/opt/cni/bin/ubicni-ipam-store").and_return(true)
      allow(File).to receive(:exist?).with("/etc/netns/test-ns/resolv.conf").and_return(true)
      allow(File).to receive(:readlines).and_return(["nameserver 8.8.8.8", "search local"])
      allow(ubicni).to receive(:r).and_return("link/ether 00:11:22:33:44:55", "inet6 fd00::1/64")
    end

    it "retrieves container network information" do
      allow(ENV).to receive(:[]).with("CNI_COMMAND").and_return("GET")
      allow(ENV).to receive(:[]).with("CNI_NETNS").and_return("/var/run/netns/test-ns")
      allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("eth0")

      allow(ubicni).to receive(:r).with("ip -n test-ns link show eth0").and_return(<<~OUTPUT)
        2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
          link/ether 00:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff
      OUTPUT

      allow(ubicni).to receive(:r).with("ip -n test-ns -6 addr show dev eth0").and_return(<<~OUTPUT)
        inet6 2001:db8::2/64 scope global
          valid_lft forever preferred_lft forever
      OUTPUT

      dns_config_path = "/etc/netns/test-ns/resolv.conf"
      allow(File).to receive(:exist?).with(dns_config_path).and_return(true)
      allow(File).to receive(:readlines).with(dns_config_path).and_return([
        "nameserver 10.96.0.10\n",
        "search default.svc.cluster.local svc.cluster.local cluster.local\n",
        "options ndots:5\n"
      ])

      output = ubicni.handle_get
      response = JSON.parse(output)

      expect(response).to include("cniVersion" => "1.0.0")
      expect(response["interfaces"]).to be_an(Array)
      expect(response["interfaces"]).to include(
        hash_including("name" => "eth0", "mac" => "00:11:22:33:44:55")
      )
      expect(response["ips"]).to be_an(Array)
      expect(response["ips"]).to include(
        hash_including("address" => "2001:db8::2/64")
      )
      expect(response["dns"]["nameservers"]).to eq(["10.96.0.10"])
      expect(response["dns"]["search"]).to eq("default.svc.cluster.local svc.cluster.local cluster.local".split)
    end

    it "returns empty handed if the dns config file does not exist" do
      dns_config_path = "/etc/netns/test-ns/resolv.conf"
      allow(File).to receive(:exist?).with(dns_config_path).and_return(false)

      response = JSON.parse(ubicni.handle_get)

      expect(response["dns"]["nameservers"]).to eq([])
      expect(response["dns"]["search"]).to eq([])
    end
  end

  describe "#gen_mac" do
    it "generates a valid MAC address" do
      expect(gen_mac).to match(/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)
    end
  end

  describe "#find_random_available_ip" do
    let(:subnet) { IPAddr.new("192.168.1.0/24") }
    let(:subnetipv6) { IPAddr.new("fd00::/64") }

    it "returns an IP address within the subnet" do
      ip = ubicni.find_random_available_ip(subnet)
      expect(subnet.include?(ip)).to be true
    end

    it "returns an IP address within the IPv6 subnet" do
      ip = ubicni.find_random_available_ip(subnetipv6)
      expect(subnetipv6.include?(ip)).to be true
    end

    it "raises an error when all available ipv4 IPs are allocated" do
      all_ips = (1..254).map { |i| "192.168.1.#{i}" }
      ubicni.instance_variable_set(:@ipam_store, {"allocated_ips" => {"test-container" => all_ips}})

      expect { ubicni.find_random_available_ip(subnet) }.to raise_error(RuntimeError, /No available IPs in subnet/)
    end

    it "raises an error when all available IPv6 IPs are allocated" do
      subnet = IPAddr.new("fd00::/126")
      # Usable host range: fd00::2 to fd00::2 (only one usable IP based on offset logic)
      allocated_ips = ["fd00::2"]

      ubicni.instance_variable_set(:@ipam_store, {
        "allocated_ips" => {
          "test-container" => allocated_ips
        }
      })

      expect { ubicni.find_random_available_ip(subnet) }.to raise_error(RuntimeError, /Could not find an available IP after 100 retries/)
    end

    it "does not accidentally reuse an ip twice" do
      all_ips = (1..252).map { |i| "192.168.1.#{i}" }
      ubicni.instance_variable_set(:@ipam_store, {"allocated_ips" => {"test-container" => all_ips}})
      ip = ubicni.find_random_available_ip(subnet)
      expect(ubicni.find_random_available_ip(subnet, reserved_ips: [ip.to_s]).to_s).not_to eq(ip.to_s)
    end
  end

  describe "#mac_to_ipv6_link_local" do
    it "converts a MAC address to an IPv6 link-local address" do
      mac_address = "00:11:22:33:44:55"
      expected_ipv6 = "fe80::0211:22ff:fe33:4455"

      expect(mac_to_ipv6_link_local(mac_address)).to eq(expected_ipv6)
    end
  end

  describe "#calculate_subnet_size" do
    it "calculates subnet size for an IPv4 subnet" do
      subnet = IPAddr.new("192.168.1.0/24")
      expect(ubicni.calculate_subnet_size(subnet)).to eq(256)
    end

    it "calculates subnet size for an IPv6 subnet" do
      subnet = IPAddr.new("fd00::/64")
      expect(ubicni.calculate_subnet_size(subnet)).to eq(2**64)
    end
  end

  describe "#check_required_env_vars" do
    it "does not call error_exit when all required variables are set" do
      allow(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("some_value")
      allow(ENV).to receive(:[]).with("CNI_NETNS").and_return("some_value")
      allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).not_to receive(:error_exit)
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end

    it "calls error_exit when a required variable is missing" do
      allow(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("some_value")
      allow(ENV).to receive(:[]).with("CNI_NETNS").and_return(nil)
      allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_NETNS")
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end

    it "calls error_exit for each missing variable" do
      allow(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return(nil)
      allow(ENV).to receive(:[]).with("CNI_NETNS").and_return(nil)
      allow(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_CONTAINERID")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_NETNS")
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end
  end
end
