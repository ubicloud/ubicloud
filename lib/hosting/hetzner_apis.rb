# frozen_string_literal: true

require "excon"
class Hosting::HetznerApis
  FailoverSubnet = Struct.new(:ips, :subnets, :failovers)

  def initialize(hetzner_host)
    @host = hetzner_host
  end

  # Fetches and processes the IPs, subnets, and failovers from the Hetzner API.
  # It then calls `find_matching_ips` to retrieve IP addresses that match with
  # the host's IP address. This whole thing is needed because Hetzner API is
  # simply not good enough to do this in one call. Also the failover IP
  # implementation depends on the host server and the IP continues to live under
  # the original server. host even if the failover is performed. So we need to
  # check the failover IP separately.
  def pull_ips
    connection = Excon.new(@host.connection_string, user: @host.user, password: @host.password)
    response = connection.get(path: "/subnet")
    if response.status != 200
      raise "unexpected status #{response.status}"
    end
    json_arr_subnets = JSON.parse(response.body)

    response = connection.get(path: "/ip")
    if response.status != 200
      raise "unexpected status #{response.status}"
    end
    json_arr_ips = JSON.parse(response.body)

    response = connection.get(path: "/failover")
    if response.status != 200 && response.status != 404
      raise "unexpected status #{response.status}"
    end
    json_arr_failover = (response.status == 404) ? [] : JSON.parse(response.body)

    addresses_with_assignment = process_ips_subnets_failovers(json_arr_ips, json_arr_subnets, json_arr_failover)
    find_matching_ips(addresses_with_assignment)
  end

  def process_ips_subnets_failovers(ips, subnets, failovers)
    failovers_map = failovers.each_with_object({}) do |failover, map|
      map[failover["failover"]["ip"]] = failover
    end

    {ips: process_items(ips, failovers_map), subnets: process_items(subnets, failovers_map)}
  end

  def process_items(items, failovers_map)
    items.map do |item|
      item_info = item[item.keys.first]
      failover_info = failovers_map[item_info["ip"]]

      item_info["failover_ip"] = !!failover_info
      item_info["active_server_ip"] = failover_info ? failover_info["failover"]["active_server_ip"] : item_info["server_ip"]

      item_info
    end
  end

  IpInfo = Struct.new(:ip_address, :source_host_ip, :is_failover, keyword_init: true)

  # Finds IP addresses that match with the host's IP address. An important
  # detail about this function is that; Hetzner API returns the failover IPv6
  # addresses with active_server_ip set to the host's IPv6 address. Here in the
  # below, you will realize that we only check the sshable.host address which is
  # the host's IPv4 address. Therefore, the additional IPv6 subnets will be
  # filtered out. If in future, this needs to be fixed, we'll have to find a way
  # to also add the IPv6 subnets.
  def find_matching_ips(result)
    host_address = @host.vm_host.sshable.host
    (
      # Aggregate single-ip addresses.
      result[:ips].filter_map do |ip|
        next unless ip["active_server_ip"] == host_address
        IpInfo.new(
          ip_address: "#{ip["ip"]}/32",
          source_host_ip: ip["server_ip"],
          is_failover: ip["failover_ip"]
        )
      end +

      # Aggregate subnets (including IPv6 /64 blocks).
      result[:subnets].filter_map do |subnet|
        next unless subnet["active_server_ip"] == host_address

        # Check if it is IPv6 or not by the existence of colon in the IP address
        mask = subnet["ip"].include?(":") ? 64 : subnet.fetch("mask")

        IpInfo.new(
          ip_address: "#{subnet["ip"]}/#{mask}",
          source_host_ip: subnet["server_ip"],
          is_failover: subnet["failover_ip"]
        )
      end
    )
  end
end
