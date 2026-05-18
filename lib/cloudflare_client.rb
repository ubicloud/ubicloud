# frozen_string_literal: true

require "excon"
require "json"

class CloudflareClient
  def initialize(api_key)
    @connection = Excon.new("https://api.cloudflare.com", headers: {"Authorization" => "Bearer #{api_key}"})
  end

  def create_token(name, policies)
    response = @connection.post(path:, body: {name:, policies:}.to_json, expects: 200)
    data = JSON.parse(response.body)
    [data["result"]["id"], data["result"]["value"]]
  end

  def delete_token(token_id)
    @connection.delete(path: "#{path}/#{token_id}", expects: [200, 404]).status
  end

  def zone_id_by_name(zone_name)
    response = @connection.get(path: "/client/v4/zones", query: {name: zone_name}, expects: 200)
    result = JSON.parse(response.body).fetch("result")
    fail "Cloudflare zone not found: #{zone_name}" if result.empty?
    result.first.fetch("id")
  end

  def ensure_dns_record(zone_id, type:, name:, content:, ttl: 60, proxied: false)
    list_response = @connection.get(
      path: "/client/v4/zones/#{zone_id}/dns_records",
      query: {name:, type:},
      expects: 200,
    )

    matching_id = nil
    JSON.parse(list_response.body).fetch("result").each do |record|
      if record["content"] == content && record["ttl"] == ttl && record["proxied"] == proxied
        matching_id = record.fetch("id")
      else
        delete_dns_record(zone_id, record.fetch("id"))
      end
    end
    return matching_id if matching_id

    create_response = @connection.post(
      path: "/client/v4/zones/#{zone_id}/dns_records",
      headers: {"Content-Type" => "application/json"},
      body: {type:, name:, content:, ttl:, proxied:}.to_json,
      expects: 200,
    )
    JSON.parse(create_response.body).fetch("result").fetch("id")
  end

  def delete_dns_record(zone_id, record_id)
    @connection.delete(path: "/client/v4/zones/#{zone_id}/dns_records/#{record_id}", expects: [200, 404]).status
  end

  def delete_dns_records(zone_id, record_ids)
    record_ids.each { delete_dns_record(zone_id, it) }
  end

  private

  def path
    frag = Config.github_cache_blob_storage_use_account_token ? "accounts/#{Config.github_cache_blob_storage_account_id}" : "user"
    "/client/v4/#{frag}/tokens"
  end
end
