# frozen_string_literal: true

require "excon"
require "json"

class CloudflareClient
  def initialize(api_key)
    @connection = Excon.new("https://api.cloudflare.com", headers: {
      "Authorization" => "Bearer #{api_key}",
      "Content-Type" => "application/json"
    })
  end

  def generate_temp_credentials(account_id:, bucket:, permission:, parent_access_key_id:, ttl_seconds: 86400)
    response = @connection.post(
      path: "/client/v4/accounts/#{account_id}/r2/temp-access-credentials",
      body: {
        bucket:,
        parentAccessKeyId: parent_access_key_id,
        permission:,
        ttlSeconds: ttl_seconds
      }.to_json,
      expects: 200
    )

    result = JSON.parse(response.body).fetch("result")
    {
      access_key_id: result.fetch("accessKeyId"),
      secret_access_key: result.fetch("secretAccessKey"),
      session_token: result.fetch("sessionToken")
    }
  end

  def create_token(name, policies)
    response = @connection.post(path:, body: {name:, policies:}.to_json, expects: 200)
    data = JSON.parse(response.body)
    [data["result"]["id"], data["result"]["value"]]
  end

  def delete_token(token_id)
    @connection.delete(path: "#{path}/#{token_id}", expects: [200, 404]).status
  end

  private

  def path
    frag = Config.github_cache_blob_storage_use_account_token ? "accounts/#{Config.github_cache_blob_storage_account_id}" : "user"
    "/client/v4/#{frag}/tokens"
  end
end
