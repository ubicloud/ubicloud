# frozen_string_literal: true

require "excon"
class Hosting::LeasewebApis < Hosting::ProviderApis
  def hardware_reset
    create_connection.post(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/powerCycle", expects: 204)
    nil
  end

  # Leaseweb has no power button API, so this maps to the powerOn call and
  # cannot power off a running server.
  def power_button
    create_connection.post(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/powerOn", expects: 204)
    nil
  end

  # Returns the power status reported by the PDU, "on" or "off". The server
  # can still be powered off while the PDU reports "on", e.g. if it was shut
  # down via IPMI.
  def power_status
    response = create_connection.get(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/powerInfo", expects: 200)
    JSON.parse(response.body).dig("pdu", "status")
  end

  def set_server_name(server_name)
    create_connection.put(path: "/bareMetals/v2/servers/#{@provider.server_identifier}",
      body: JSON.generate(reference: server_name),
      expects: 204)
    nil
  end

  def pull_data_center
    response = create_connection.get(path: "/bareMetals/v2/servers/#{@provider.server_identifier}", expects: 200)
    location = JSON.parse(response.body).fetch("location")
    [location["site"], location["suite"], location["rack"]].compact.join("-")
  end

  private

  def create_connection
    Excon.new(Config.leaseweb_connection_string,
      headers: {"X-Lsw-Auth" => Config.leaseweb_api_key, "Content-Type" => "application/json"})
  end
end
