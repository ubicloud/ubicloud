# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/network"
require "fileutils"
require "ipaddr"
require "securerandom"
require "json"
require "logger"

class UbiCNI
  MTU = 1400
  IPAM_STORE_FILE = "/opt/cni/bin/ubicni-ipam-store"
  def initialize(input_data, logger)
    @input_data = input_data
    @logger = logger
    @cni_command = ENV["CNI_COMMAND"]
  end

  def run
    log_environment
    output = case @cni_command
    when "ADD" then handle_add
    when "DEL" then handle_del
    else error_exit("Unsupported CNI command: #{@cni_command}")
    end
    puts output
  end

  def log_environment
    @logger.info <<~LOG
      -------------------------------------------------------
      Handling new command: #{@cni_command}
      ENV[CNI_CONTAINERID] #{ENV["CNI_CONTAINERID"]}
      ENV[CNI_NETNS] #{ENV["CNI_NETNS"]}
      ENV[CNI_IFNAME] #{ENV["CNI_IFNAME"]}
      ENV[CNI_ARGS] #{ENV["CNI_ARGS"]}
      ENV[CNI_PATH] #{ENV["CNI_PATH"]}
      -------------------------------------------------------
    LOG
  end

  def handle_add
    check_required_env_vars(["CNI_CONTAINERID", "CNI_NETNS", "CNI_IFNAME"])
    validate_input_ranges

    subnet_ula_ipv6 = @input_data["ranges"]["subnet_ula_ipv6"]
    subnet_ipv6 = @input_data["ranges"]["subnet_ipv6"]
    subnet_ipv4 = @input_data["ranges"]["subnet_ipv4"]

    container_id = ENV["CNI_CONTAINERID"]
    cni_netns = ENV["CNI_NETNS"].sub("/var/run/netns/", "")
    inner_ifname = ENV["CNI_IFNAME"]

    @logger.info "Generating MAC addresses for container #{container_id}"
    inner_mac = gen_mac
    outer_mac = gen_mac
    inner_link_local = mac_to_ipv6_link_local(inner_mac)
    outer_link_local = mac_to_ipv6_link_local(outer_mac)
    outer_ifname = "veth_#{container_id[0, 8]}"

    @logger.info "Configuring DNS for network namespace #{cni_netns}"
    setup_dns(cni_netns)

    @logger.info "Setting up veth pair for container #{container_id}"
    r "ip link add #{outer_ifname} addr #{outer_mac} type veth peer name #{inner_ifname} addr #{inner_mac} netns #{cni_netns}"

    @logger.info "Allocating IP addresses for container #{container_id}"
    ipv4_container_ip, ipv4_gateway_ip, container_ula_ipv6, container_ipv6 = allocate_ips_for_pod(container_id, subnet_ula_ipv6, subnet_ipv6, subnet_ipv4)
    @logger.info "Setting up IPv6 configurations"
    setup_ipv6(container_ipv6, inner_link_local, outer_link_local, cni_netns, inner_ifname, outer_ifname, setup_default_route: true)
    setup_ipv6(container_ula_ipv6, inner_link_local, outer_link_local, cni_netns, inner_ifname, outer_ifname)

    @logger.info "Setting up IPv4 configuration"
    setup_ipv4(ipv4_container_ip, ipv4_gateway_ip, cni_netns, inner_ifname, outer_ifname)

    response = build_add_response(inner_ifname, inner_mac, cni_netns, ipv4_container_ip, ipv4_gateway_ip, container_ula_ipv6, container_ipv6, outer_link_local)
    @logger.info "ADD response: #{JSON.generate(response)}"
    JSON.generate(response)
  end

  def build_add_response(inner_ifname, inner_mac, cni_netns, ipv4_container_ip, ipv4_gateway_ip, container_ula_ipv6, container_ipv6, outer_link_local)
    {
      cniVersion: "1.0.0",
      interfaces: [{name: inner_ifname, mac: inner_mac, sandbox: "/var/run/netns/#{cni_netns}"}],
      ips: [
        {address: "#{ipv4_container_ip}/#{ipv4_container_ip.prefix}", gateway: ipv4_gateway_ip.to_s, interface: 0},
        {address: "#{container_ula_ipv6}/#{container_ula_ipv6.prefix}", gateway: outer_link_local, interface: 0},
        {address: "#{container_ipv6}/#{container_ipv6.prefix}", gateway: outer_link_local, interface: 0}
      ],
      routes: [{dst: "0.0.0.0/0"}],
      dns: {
        nameservers: ["10.96.0.10"],
        search: ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"],
        options: ["ndots:5"]
      }
    }
  end

  def setup_dns(cni_netns)
    FileUtils.mkdir_p("/etc/netns/#{cni_netns}")
    dns_config = <<~EOF
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
    EOF
    File.write("/etc/netns/#{cni_netns}/resolv.conf", dns_config)
  end

  def allocate_ips_for_pod(container_id, subnet_ula_ipv6, subnet_ipv6, subnet_ipv4)
    result = nil
    safe_write_to_file(IPAM_STORE_FILE) do |file|
      ipam_store = begin
        content = File.read(IPAM_STORE_FILE)
        content.empty? ? {"allocated_ips" => {}} : JSON.parse(content)
      rescue Errno::ENOENT
        {"allocated_ips" => {}}
      end
      allocated_ips = ipam_store["allocated_ips"]
      subnet_ula_ipv6_obj = IPAddr.new(subnet_ula_ipv6)
      subnet_ipv6_obj = IPAddr.new(subnet_ipv6)
      subnet_ipv4_obj = IPAddr.new(subnet_ipv4)

      container_ula_ipv6 = find_random_available_ip(allocated_ips, subnet_ula_ipv6_obj)
      container_ipv6 = find_random_available_ip(allocated_ips, subnet_ipv6_obj)
      ipv4_container_ip = find_random_available_ip(allocated_ips, subnet_ipv4_obj)
      ipv4_gateway_ip = find_random_available_ip(allocated_ips, subnet_ipv4_obj, reserved_ips: [ipv4_container_ip.to_s])

      allocated_ips[container_id] = [
        ipv4_container_ip.to_s,
        ipv4_gateway_ip.to_s,
        container_ula_ipv6.to_s,
        container_ipv6.to_s
      ]
      file.write(JSON.pretty_generate(ipam_store))
      file.flush
      file.fsync
      result = [ipv4_container_ip, ipv4_gateway_ip, container_ula_ipv6, container_ipv6]
    end
    result
  end

  def setup_ipv6(container_ip, inner_link_local, outer_link_local, cni_netns, inner_ifname, outer_ifname, setup_default_route: false)
    r "ip -6 -n #{cni_netns} addr replace #{container_ip}/#{container_ip.prefix} dev #{inner_ifname}"
    r "ip -6 -n #{cni_netns} link set #{inner_ifname} mtu #{MTU} up"
    if setup_default_route
      r "ip -6 -n #{cni_netns} route replace default via #{outer_link_local} dev #{inner_ifname}"
    end

    r "ip -6 link set #{outer_ifname} mtu #{MTU} up"
    r "ip -6 route replace #{container_ip}/#{container_ip.prefix} via #{inner_link_local} dev #{outer_ifname} mtu #{MTU}"
  end

  def setup_ipv4(container_ip, gateway_ip, cni_netns, inner_ifname, outer_ifname)
    r "ip addr replace #{gateway_ip}/24 dev #{outer_ifname}"
    r "ip link set #{outer_ifname} mtu #{MTU} up"

    r "ip -n #{cni_netns} addr replace #{container_ip}/24 dev #{inner_ifname}"
    r "ip -n #{cni_netns} link set #{inner_ifname} mtu #{MTU} up"
    r "ip -n #{cni_netns} route replace default via #{gateway_ip}"

    r "ip route replace #{container_ip}/#{container_ip.prefix} via #{gateway_ip} dev #{outer_ifname}"
    r "echo 1 > /proc/sys/net/ipv4/conf/#{outer_ifname}/proxy_arp"
  end

  def handle_del
    check_required_env_vars(["CNI_CONTAINERID"])
    container_id = ENV["CNI_CONTAINERID"]
    @logger.info "Releasing IPs for container #{container_id}"
    safe_write_to_file(IPAM_STORE_FILE) do |file|
      ipam_store = begin
        content = File.read(IPAM_STORE_FILE)
        content.empty? ? {"allocated_ips" => {}} : JSON.parse(content)
      rescue Errno::ENOENT
        {"allocated_ips" => {}}
      end

      ipam_store["allocated_ips"].delete(container_id)
      file.write(JSON.pretty_generate(ipam_store))
      file.flush
      file.fsync
    end

    "{}"
  end

  def error_exit(message)
    @logger.error message
    puts JSON.generate({code: 100, msg: message})
    exit 1
  end

  def find_random_available_ip(allocated_ips, subnet, reserved_ips: [])
    unavailable_ips = allocated_ips.values.flatten.concat(reserved_ips)

    if subnet.ipv4?
      available_ips = generate_all_usable_ips(subnet)
      available_ips.reject! { |ip| unavailable_ips.include?(ip.to_s) }
      raise "No available IPs in subnet #{subnet}" if available_ips.empty?

      available_ips.sample
    else
      max_retries = 100
      max_retries.times do
        ip = generate_random_ip(subnet)
        unless unavailable_ips.include?(ip.to_s)
          return ip
        end
      end
      raise "Could not find an available IP after #{max_retries} retries"
    end
  end

  def generate_random_ip(subnet)
    subnet_size = calculate_subnet_size(subnet)

    base = subnet.to_i & subnet.mask(subnet.prefix).to_i
    # We subtract 3 from subnet_size:
    #   - 1 for the network address (offset 0)
    #   - 1 for the first usable IP (offset 1)
    #   - 1 for the broadcast address (offset = subnet_size - 1)
    #
    # Then we add 2 to the result of random_number so offsets start at 2.
    random_offset = SecureRandom.random_number(subnet_size - 3) + 2
    IPAddr.new(base + random_offset, Socket::AF_INET6)
  end

  def generate_all_usable_ips(subnet)
    subnet_size = calculate_subnet_size(subnet)
    base = subnet.to_i & subnet.mask(subnet.prefix).to_i

    # Valid host IPs range from offset 2 to subnet_size - 2
    (2...(subnet_size - 1)).map do |offset|
      IPAddr.new(base + offset, Socket::AF_INET)
    end
  end

  def calculate_subnet_size(subnet)
    if subnet.ipv4?
      2**(32 - subnet.prefix)
    else
      2**(128 - subnet.prefix)
    end
  end

  def check_required_env_vars(vars)
    vars.each do |var|
      error_exit("Missing required environment variable: #{var}") unless ENV[var]
    end
  end

  def validate_input_ranges
    unless @input_data["ranges"]&.values_at("subnet_ula_ipv6", "subnet_ipv6", "subnet_ipv4")&.all?
      error_exit("Missing required ranges in input data")
    end
  end
end
