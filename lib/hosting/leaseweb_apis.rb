# frozen_string_literal: true

require "excon"
class Hosting::LeasewebApis
  def initialize(leaseweb_host)
    @host = leaseweb_host
  end

  def get_main_ip4
    connection = Excon.new(@host.connection_string,
      headers: {"X-LSW-Auth" => @host.secret})
    response = connection.get(path: "/bareMetals/v2/servers/#{@host.server_identifier}/ips",
      body: URI.encode_www_form(version: "4", networkType: "PUBLIC", limit: 0, offset: 0),
      expects: 200)

    response_hash = JSON.parse(response.body)
    response_hash["ips"].find { |ip| ip["mainIp"] }
  end

  IpInfo = Struct.new(:ip_address, :source_host_ip, :is_failover, :gateway, :mask, keyword_init: true)

  def pull_ips
    connection = Excon.new(@host.connection_string, headers: {"X-LSW-Auth" => @host.secret})
    ip_records = fetch_all_ip_records(connection)
    process_ip_records(ip_records)
  end

  private

  def fetch_all_ip_records(connection)
    offset = 0
    ip_records = []

    loop do
      response = connection.get(path: "/bareMetals/v2/servers/#{@host.server_identifier}/ips",
        query: {networkType: "PUBLIC", limit: 50, offset: offset},
        expects: 200)
      response_hash = JSON.parse(response.body)

      ip_records.concat(parse_ip_records(response_hash["ips"]))

      offset += response_hash["ips"].count
      break if response_hash["ips"].count < 50
    end

    ip_records
  end

  def parse_ip_records(ips)
    ips.map do |ip|
      ip_addr = normalize_ip_address(ip["ip"])
      IpInfo.new(
        ip_address: ip_addr,
        gateway: (ip["gateway"] == "") ? nil : ip["gateway"],
        is_failover: false,
        mask: ip["prefixLength"]
      )
    end
  end

  def normalize_ip_address(ip)
    if ip.include?("_")
      ip.split("/").first.tr("_", "/")
    else
      ip
    end
  end

  def ipv6?(ip_info)
    ip_info.ip_address.include?("::")
  end

  def process_ip_records(ip_records)
    ip_records.group_by { |ip| NetAddr.parse_net(ip.ip_address).network.to_s }
      .flat_map do |network, ips|
        if ipv6?(ips.first)
          [IpInfo.new(
            ip_address: ips.first.ip_address,
            gateway: ips.first.gateway,
            is_failover: ips.first.is_failover,
            mask: ips.first.ip_address.split("/").last.to_i
          )]
        else
          process_ipv4_records(network, ips)
        end
      end
  end

  def process_ipv4_records(network, ips)
    first_ip = ips.first
    net_addr, mask = if first_ip.gateway
      ["#{first_ip.ip_address.split("/").first}/32", first_ip.mask]
    else
      [network.to_s + "/" + first_ip.mask.to_s, first_ip.mask]
    end

    [IpInfo.new(
      ip_address: net_addr,
      gateway: (first_ip.gateway == "") ? nil : first_ip.gateway,
      is_failover: first_ip.is_failover,
      mask: mask
    )]
  end
end
