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
  end

  describe "#run" do
    it "calls handle_add if CNI_COMMAND is ADD" do
      expect(ENV).to receive(:[]).with("CNI_COMMAND").and_return("ADD")
      expect(ubicni).to receive(:handle_add).and_return("add_output")
      expect { ubicni.run }.to output("add_output\n").to_stdout
    end

    it "calls handle_del if CNI_COMMAND is DEL" do
      expect(ENV).to receive(:[]).with("CNI_COMMAND").and_return("DEL")
      expect(ubicni).to receive(:handle_del).and_return("del_output")
      expect { ubicni.run }.to output("del_output\n").to_stdout
    end

    it "raises an error for an unsupported command" do
      expect(ENV).to receive(:[]).with("CNI_COMMAND").and_return("INVALID")
      expect(logger).to receive(:error).with("Unsupported CNI command: INVALID")
      expect { ubicni.run }.to output("{\"code\":100,\"msg\":\"Unsupported CNI command: INVALID\"}\n").to_stdout.and raise_error(SystemExit)
    end
  end

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
      expect(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("abcdef123456")
      expect(ENV).to receive(:[]).with("CNI_COMMAND").and_return("ADD")
      expect(ENV).to receive(:[]).with("CNI_NETNS").and_return("/var/run/netns/testnetns")
      expect(ENV).to receive(:[]).with("CNI_IFNAME").and_return("eth0")

      expect(FileUtils).to receive(:mkdir_p)
      expect(File).to receive(:write)
      expect(ubicni).to receive(:gen_mac).and_return("00:11:22:33:44:55", "00:aa:bb:cc:dd:ee")
      expect(ubicni).to receive(:mac_to_ipv6_link_local).with("00:11:22:33:44:55").and_return("fe80::0211:22ff:fe33:4455")
      expect(ubicni).to receive(:mac_to_ipv6_link_local).with("00:aa:bb:cc:dd:ee").and_return("fe80::02aa:bbff:fecc:ddee")
      expect(ubicni).to receive(:find_random_available_ip).and_return(
        container_ipv6, container_ula_ipv6, ipv4_container_ip, ipv4_gateway_ip
      )
    end

    it "sets up networking, assigns IPs, and updates the IPAM store" do
      ipam_store = {"allocated_ips" => {}}
      expect(ubicni).to receive(:safe_write_to_file) do |filename, &block|
        expect(File).to receive(:read).with(filename).and_return(JSON.pretty_generate(ipam_store))
        file = instance_double(File)
        expect(file).to receive(:write) do |content|
          ipam_store.replace(JSON.parse(content))
        end
        expect(file).to receive(:flush)
        expect(file).to receive(:fsync)
        block.call(file)
      end

      expect(ubicni).to receive(:check_required_env_vars).with(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
      expect(ubicni).to receive(:validate_input_ranges)

      expect_run = ->(cmd) { expect(ubicni).to receive(:r).with(cmd) }
      expect_run["ip link add veth_abcdef12 addr 00:aa:bb:cc:dd:ee type veth peer name eth0 addr 00:11:22:33:44:55 netns testnetns"]
      expect_run["ip -6 -n testnetns addr replace 2001:db8::2/128 dev eth0"]
      expect_run["ip -6 -n testnetns link set eth0 mtu 1400 up"]
      expect_run["ip -6 -n testnetns route replace default via fe80::02aa:bbff:fecc:ddee dev eth0"]
      expect_run["ip -6 link set veth_abcdef12 mtu 1400 up"]
      expect_run["ip -6 route replace 2001:db8::2/128 via fe80::0211:22ff:fe33:4455 dev veth_abcdef12 mtu 1400"]

      expect_run["ip -6 -n testnetns addr replace fd00::2/128 dev eth0"]
      expect_run["ip -6 -n testnetns link set eth0 mtu 1400 up"]
      expect_run["ip -6 link set veth_abcdef12 mtu 1400 up"]
      expect_run["ip -6 route replace fd00::2/128 via fe80::0211:22ff:fe33:4455 dev veth_abcdef12 mtu 1400"]

      expect_run["ip addr replace 192.168.1.1/24 dev veth_abcdef12"]
      expect_run["ip link set veth_abcdef12 mtu 1400 up"]
      expect_run["ip -n testnetns addr replace 192.168.1.100/24 dev eth0"]
      expect_run["ip -n testnetns link set eth0 mtu 1400 up"]
      expect_run["ip -n testnetns route replace default via 192.168.1.1"]
      expect_run["ip route replace 192.168.1.100/32 via 192.168.1.1 dev veth_abcdef12"]
      expect_run["echo 1 > /proc/sys/net/ipv4/conf/veth_abcdef12/proxy_arp"]

      output = ubicni.handle_add
      response = JSON.parse(output)

      expect(response).to include("cniVersion" => "1.0.0")
      expect(response["interfaces"]).to include(
        hash_including("name" => "eth0", "mac" => "00:11:22:33:44:55", "sandbox" => "/var/run/netns/testnetns")
      )
      expect(response["ips"]).to include(
        hash_including("address" => "192.168.1.100/32", "gateway" => "192.168.1.1", "interface" => 0),
        hash_including("address" => "fd00::2/128", "gateway" => "fe80::02aa:bbff:fecc:ddee", "interface" => 0),
        hash_including("address" => "2001:db8::2/128", "gateway" => "fe80::02aa:bbff:fecc:ddee", "interface" => 0)
      )
      expect(response["routes"]).to include(hash_including("dst" => "0.0.0.0/0"))
      expect(response["dns"]).to include(
        "nameservers" => ["10.96.0.10"],
        "search" => ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"],
        "options" => ["ndots:5"]
      )

      expect(ipam_store["allocated_ips"]["abcdef123456"]).to contain_exactly(
        "192.168.1.100",
        "192.168.1.1",
        "fd00::2",
        "2001:db8::2"
      )
    end
  end

  describe "#handle_del" do
    let(:ipam_store_file) { UbiCNI::IPAM_STORE_FILE }
    let(:container_id) { "1234" }

    before do
      expect(ubicni).to receive(:check_required_env_vars).with(["CNI_CONTAINERID"])
      ENV["CNI_CONTAINERID"] = container_id
    end

    it "handles an empty store when the file exists but is empty" do
      expect(File).to receive(:read).with(ipam_store_file).and_return("")
      file = instance_double(File)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)
      expect(file).to receive(:write) do |written|
        parsed = JSON.parse(written)
        expect(parsed["allocated_ips"]).to eq({})
      end
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni.handle_del).to eq("{}")
    end

    it "handles a non-empty store and removes the container IPs" do
      initial_store = {"allocated_ips" => {container_id => ["192.168.1.2"], "other" => ["192.168.1.3"]}}
      initial_content = JSON.pretty_generate(initial_store)
      expect(File).to receive(:read).with(ipam_store_file).and_return(initial_content)
      file = instance_double(File)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)
      expect(file).to receive(:write) do |written|
        parsed = JSON.parse(written)
        expect(parsed["allocated_ips"]).to eq({"other" => ["192.168.1.3"]}) # container_id removed
      end
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni.handle_del).to eq("{}")
    end

    it "handles the case when the file does not exist" do
      expect(File).to receive(:read).with(ipam_store_file).and_raise(Errno::ENOENT)
      file = instance_double(File)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)
      expect(file).to receive(:write) do |written|
        parsed = JSON.parse(written)
        expect(parsed["allocated_ips"]).to eq({})
      end
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni.handle_del).to eq("{}")
    end
  end

  describe "#allocate_ips_for_pod" do
    let(:subnet_ula_ipv6) { "fc00::/64" }
    let(:subnet_gua_ipv6) { "fd00::/64" }
    let(:subnet_ipv4) { "192.168.1.0/24" }
    let(:container_id) { "abc123" }
    let(:ipam_store_file) { UbiCNI::IPAM_STORE_FILE }

    let(:ipv4_container_ip) { IPAddr.new("192.168.1.100") }
    let(:ipv4_gateway_ip) { IPAddr.new("192.168.1.1") }
    let(:ipv6_container_ip) { IPAddr.new("fd00::2") }
    let(:ula_container_ip) { IPAddr.new("fc00::2") }

    before do
      expect(ubicni).to receive(:find_random_available_ip).and_return(
        ula_container_ip, ipv6_container_ip, ipv4_container_ip, ipv4_gateway_ip
      )
    end

    it "parses content when file exists and contains JSON" do
      initial_store = {"allocated_ips" => {"existing" => ["192.168.1.99"]}}
      expect(File).to receive(:read).with(ipam_store_file).and_return(JSON.generate(initial_store))
      file = instance_double(File)
      expect(file).to receive(:write)
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)

      result = ubicni.allocate_ips_for_pod(container_id, subnet_ula_ipv6, subnet_gua_ipv6, subnet_ipv4)
      expect(result).to eq([ipv4_container_ip, ipv4_gateway_ip, ula_container_ip, ipv6_container_ip])
    end

    it "uses default store when file exists but is empty" do
      expect(File).to receive(:read).with(ipam_store_file).and_return("")
      file = instance_double(File)
      expect(file).to receive(:write)
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)

      result = ubicni.allocate_ips_for_pod(container_id, subnet_ula_ipv6, subnet_gua_ipv6, subnet_ipv4)
      expect(result).to eq([ipv4_container_ip, ipv4_gateway_ip, ula_container_ip, ipv6_container_ip])
    end

    it "initializes store when file does not exist" do
      expect(File).to receive(:read).with(ipam_store_file).and_raise(Errno::ENOENT)
      file = instance_double(File)
      expect(file).to receive(:write)
      expect(file).to receive(:flush)
      expect(file).to receive(:fsync)
      expect(ubicni).to receive(:safe_write_to_file).with(ipam_store_file).and_yield(file)

      result = ubicni.allocate_ips_for_pod(container_id, subnet_ula_ipv6, subnet_gua_ipv6, subnet_ipv4)
      expect(result).to eq([ipv4_container_ip, ipv4_gateway_ip, ula_container_ip, ipv6_container_ip])
    end
  end

  describe "#gen_mac" do
    it "generates a valid MAC address" do
      expect(gen_mac).to match(/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)
    end
  end

  describe "#find_random_available_ip" do
    let(:ipv4_subnet) { IPAddr.new("192.168.1.0/24") }
    let(:ipv6_subnet) { IPAddr.new("fd00::/64") }
    let(:ipam_store) { {"allocated_ips" => {"test-container" => ["192.168.1.2"]}} }

    it "returns an IP address within the IPv4 subnet" do
      ip = ubicni.find_random_available_ip(ipam_store["allocated_ips"], ipv4_subnet)
      expect(ipv4_subnet.include?(ip)).to be true
      expect(ip.to_s).not_to eq("192.168.1.2")
    end

    it "returns an IP address within the IPv6 subnet" do
      ip = ubicni.find_random_available_ip(ipam_store["allocated_ips"], ipv6_subnet)
      expect(ipv6_subnet.include?(ip)).to be true
    end

    it "raises an error when all available IPv4 IPs are allocated" do
      all_ips = (1..254).map { |i| "192.168.1.#{i}" }
      ipam_store_all = {"allocated_ips" => {"test" => all_ips}}
      expect { ubicni.find_random_available_ip(ipam_store_all["allocated_ips"], ipv4_subnet) }
        .to raise_error(/No available IPs in subnet 192.168.1.0/)
    end

    it "avoids reserved IPs" do
      ip = ubicni.find_random_available_ip(ipam_store["allocated_ips"], ipv4_subnet, reserved_ips: ["192.168.1.3"])
      expect(ip.to_s).not_to eq("192.168.1.2")
      expect(ip.to_s).not_to eq("192.168.1.3")
    end

    it "returns an available IP within the IPv6 subnet and avoids allocated IPs" do
      allocated_ips = {"test-container" => ["fd00::1"]}
      expect(ubicni).to receive(:generate_random_ip).and_return(IPAddr.new("fd00::2"))
      ip = ubicni.find_random_available_ip(allocated_ips, ipv6_subnet)
      expect(ipv6_subnet.include?(ip)).to be true
      expect(ip.to_s).not_to eq("fd00::1")
    end

    it "raises an error when no available IP is found after max retries for IPv6" do
      allocated_ips = {"test-container" => ["fd00::1"]}
      allow(ubicni).to receive(:generate_random_ip).and_return(IPAddr.new("fd00::1"))
      expect {
        ubicni.find_random_available_ip(allocated_ips, ipv6_subnet)
      }.to raise_error("Could not find an available IP after 100 retries")
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
      expect(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("some_value")
      expect(ENV).to receive(:[]).with("CNI_NETNS").and_return("some_value")
      expect(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).not_to receive(:error_exit)
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end

    it "calls error_exit when a required variable is missing" do
      expect(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return("some_value")
      expect(ENV).to receive(:[]).with("CNI_NETNS").and_return(nil)
      expect(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_NETNS")
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end

    it "calls error_exit for each missing variable" do
      expect(ENV).to receive(:[]).with("CNI_CONTAINERID").and_return(nil)
      expect(ENV).to receive(:[]).with("CNI_NETNS").and_return(nil)
      expect(ENV).to receive(:[]).with("CNI_IFNAME").and_return("some_value")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_CONTAINERID")
      expect(ubicni).to receive(:error_exit).with("Missing required environment variable: CNI_NETNS")
      ubicni.check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    end
  end

  describe "#validate_input_ranges" do
    context "when all required ranges are present" do
      subject(:ubicni) { described_class.new(input, logger) }

      let(:input) do
        {
          "ranges" => {
            "subnet_ula_ipv6" => "fd00::/64",
            "subnet_ipv6" => "2001:db8::/64",
            "subnet_ipv4" => "192.168.1.0/24"
          }
        }
      end

      it "does not call error_exit" do
        expect(ubicni).not_to receive(:error_exit)
        ubicni.validate_input_ranges
      end
    end

    context "when 'ranges' key is missing" do
      subject(:ubicni) { described_class.new(input, logger) }

      let(:input) { {} }

      it "calls error_exit with the appropriate message" do
        expect(ubicni).to receive(:error_exit).with("Missing required ranges in input data")
        ubicni.validate_input_ranges
      end
    end

    context "when one of the required ranges is missing" do
      subject(:ubicni) { described_class.new(input, logger) }

      let(:input) do
        {
          "ranges" => {
            "subnet_ula_ipv6" => "fd00::/64",
            "subnet_ipv4" => "192.168.1.0/24"
          }
        }
      end

      it "calls error_exit with the appropriate message" do
        expect(ubicni).to receive(:error_exit).with("Missing required ranges in input data")
        ubicni.validate_input_ranges
      end
    end

    context "when one of the required ranges is nil" do
      subject(:ubicni) { described_class.new(input, logger) }

      let(:input) do
        {
          "ranges" => {
            "subnet_ula_ipv6" => "fd00::/64",
            "subnet_ipv6" => nil,
            "subnet_ipv4" => "192.168.1.0/24"
          }
        }
      end

      it "calls error_exit with the appropriate message" do
        expect(ubicni).to receive(:error_exit).with("Missing required ranges in input data")
        ubicni.validate_input_ranges
      end
    end
  end
end
