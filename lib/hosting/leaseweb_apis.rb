# frozen_string_literal: true

require "excon"
class Hosting::LeasewebApis < Hosting::ProviderApis
  def hardware_reset
    create_connection.post(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/powerCycle", expects: 204)
    nil
  end

  def set_server_name(server_name)
    create_connection.put(path: "/bareMetals/v2/servers/#{@provider.server_identifier}",
      body: JSON.generate(reference: server_name),
      expects: 204)
  end

  def pull_data_center
    response = create_connection.get(path: "/bareMetals/v2/servers/#{@provider.server_identifier}", expects: 200)
    location = JSON.parse(response.body).fetch("location")
    [location["site"], location["suite"]].compact.join("-")
  end

  def create_connection
    Excon.new(Config.leaseweb_connection_string,
      headers: {"X-Lsw-Auth" => Config.leaseweb_api_key, "Content-Type" => "application/json"})
  end
end
