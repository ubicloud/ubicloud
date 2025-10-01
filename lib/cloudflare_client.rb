# frozen_string_literal: true

require "excon"
require "json"

class CloudflareClient
  def initialize(api_key)
    @connection = Excon.new("https://api.cloudflare.com", headers: {"Authorization" => "Bearer #{api_key}"})
  end

  def create_token(name, policies)
    response = @connection.post(path:, body: {name: name, policies: policies}.to_json, expects: 200)
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
