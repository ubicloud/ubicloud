# frozen_string_literal: true

require "excon"
require "ipaddr"

class Hosting::LeasewebApis
  def initialize(leaseweb_host)
    @host = leaseweb_host
  end

  IpInfo = Struct.new(:ip_address, :source_host_ip, :is_failover, :gateway, :mask, keyword_init: true)

  INFRA_IP_TYPES = %w[NETWORK GATEWAY BROADCAST ROUTER1 ROUTER2].freeze

  def pull_ips
    server_id = @host.server_identifier
    connection = create_connection

    all_ips = fetch_all_ips(connection, server_id)
    process_ips(all_ips)
  end

  def get_main_ip4
    server_id = @host.server_identifier
    response = create_connection.get(
      path: "/bareMetals/v2/servers/#{server_id}",
      expects: 200
    )

    data = JSON.parse(response.body)
    strip_cidr(data.dig("networkInterfaces", "public", "ip"))
  end

  def create_connection
    Excon.new(@host.connection_string,
      headers: {
        "X-Lsw-Auth" => Config.leaseweb_api_key,
        "Content-Type" => "application/json"
      })
  end

  private

  def fetch_all_ips(connection, server_id)
    ips = []
    offset = 0
    limit = 50

    loop do
      response = connection.get(
        path: "/bareMetals/v2/servers/#{server_id}/ips",
        query: {limit:, offset:},
        expects: 200
      )

      data = JSON.parse(response.body)
      ips.concat(data["ips"])

      total = data.dig("_metadata", "totalCount")
      break if ips.length >= total
      offset += limit
    end

    ips
  end

  def process_ips(ips)
    public_ips = ips.select { |ip| ip["networkType"] == "PUBLIC" && ip["type"] == "NORMAL_IP" }

    main_ip_entry = public_ips.find { |ip| ip["mainIp"] }
    main_ip4 = strip_cidr(main_ip_entry&.dig("ip"))

    result = []
    subnet_groups = {}

    public_ips.each do |ip_entry|
      ip = strip_cidr(ip_entry["ip"])
      prefix = ip_entry["prefixLength"]
      gateway = ip_entry["gateway"]
      is_main = ip_entry["mainIp"]

      if ip.include?("_")
        # IPv6 normalization: "2607:f5b7:1:30:9::_112" → "2607:f5b7:1:30:9::/112"
        normalized = ip.tr("_", "/")
        parts = normalized.split("/")
        ip = parts[0]
        prefix = parts[1].to_i

        result << IpInfo.new(
          ip_address: "#{ip}/#{prefix}",
          source_host_ip: main_ip4,
          is_failover: false,
          gateway: normalize_gateway(gateway),
          mask: prefix
        )
      elsif is_main || gateway_present?(gateway)
        # Main IP or IP with explicit gateway stays as /32
        result << IpInfo.new(
          ip_address: "#{ip}/32",
          source_host_ip: main_ip4,
          is_failover: false,
          gateway: normalize_gateway(gateway),
          mask: prefix
        )
      else
        # Subnet IP without gateway - group into network CIDR
        network = IPAddr.new("#{ip}/#{prefix}").to_s
        key = "#{network}/#{prefix}"
        subnet_groups[key] ||= {mask: prefix}
      end
    end

    subnet_groups.each do |cidr, info|
      result << IpInfo.new(
        ip_address: cidr,
        source_host_ip: main_ip4,
        is_failover: false,
        gateway: nil,
        mask: info[:mask]
      )
    end

    result
  end

  def strip_cidr(ip)
    return nil if ip.nil?
    ip.split("/").first
  end

  def gateway_present?(gateway)
    gateway.is_a?(String) && !gateway.empty?
  end

  def normalize_gateway(gateway)
    gateway_present?(gateway) ? gateway : nil
  end
end
