# frozen_string_literal: true

require "excon"
class Hosting::HetznerApis
  def initialize(hetzner_host)
    @host = hetzner_host
  end

  def reimage(server_id, hetzner_ssh_public_key: Config.hetzner_ssh_public_key, dist: "Debian 13 base")
    unless hetzner_ssh_public_key
      raise "hetzner_ssh_public_key is not set"
    end

    key_data = hetzner_ssh_public_key.split(" ")[1]
    decoded_data = Base64.decode64(key_data)
    fingerprint = OpenSSL::Digest::MD5.new(decoded_data).hexdigest
    formatted_fingerprint = fingerprint.scan(/../).join(":")
    connection = create_connection
    connection.post(path: "/boot/#{server_id}/linux",
      body: URI.encode_www_form(dist: dist, lang: "en", authorized_key: formatted_fingerprint),
      expects: 200)

    connection.post(path: "/reset/#{server_id}", body: "type=hw", expects: 200)
    nil
  end

  # Cuts power to a Server and starts it again. This forcefully stops it
  # without giving the Server operating system time to gracefully stop. This
  # may lead to data loss, it’s equivalent to pulling the power cord and
  # plugging it in again. Reset should only be used when reboot does not work.
  def reset(server_id)
    create_connection.post(path: "/reset/#{server_id}", body: "type=hw", expects: 200)
    nil
  end

  def add_key(name, key)
    create_connection.post(path: "/key",
      body: URI.encode_www_form(name: name, data: key),
      expects: 201)
    nil
  end

  def delete_key(key)
    key_data = key.split(" ")[1]
    decoded_data = Base64.decode64(key_data)
    fingerprint = OpenSSL::Digest::MD5.new(decoded_data).hexdigest

    create_connection.delete(path: "/key/#{fingerprint}", expects: [200, 404])
    nil
  end

  def get_main_ip4
    response = create_connection.get(path: "/server/#{@host.server_identifier}",
      expects: 200)

    response_hash = JSON.parse(response.body)
    response_hash.dig("server", "server_ip")
  end

  # Fetches and processes the IPs, subnets, and failovers from the Hetzner API.
  # It then calls `find_matching_ips` to retrieve IP addresses that match with
  # the host's IP address. This whole thing is needed because Hetzner API is
  # simply not good enough to do this in one call. Also the failover IP
  # implementation depends on the host server and the IP continues to live under
  # the original server. host even if the failover is performed. So we need to
  # check the failover IP separately.
  def pull_ips
    connection = create_connection
    response = connection.get(path: "/subnet", expects: 200)
    json_arr_subnets = JSON.parse(response.body)

    response = connection.get(path: "/ip", expects: 200)
    json_arr_ips = JSON.parse(response.body)

    response = connection.get(path: "/failover", expects: [200, 404])
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

  def pull_dc(server_id)
    response = create_connection.get(path: "/server/#{server_id}", expects: 200)
    json_server = JSON.parse(response.body)
    json_server.dig("server", "dc")
  end

  def set_server_name(server_id, name)
    create_connection.post(path: "/server/#{server_id}",
      body: URI.encode_www_form(server_name: name),
      expects: 200)
  end

  def create_connection
    Excon.new(@host.connection_string,
      user: @host.user,
      password: @host.password,
      headers: {"Content-Type" => "application/x-www-form-urlencoded"})
  end
end
