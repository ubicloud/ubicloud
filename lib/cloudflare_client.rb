# frozen_string_literal: true

require "excon"
require "json"

class CloudflareClient
  def initialize(api_key)
    @connection = Excon.new("https://api.cloudflare.com", headers: {"Authorization" => "Bearer #{api_key}"})
  end

  def create_temporary_token(bucket_name, permission, ttl)
    path = "/client/v4/accounts/#{Config.github_cache_blob_storage_account_id}/r2/temp-access-credentials"
    body = {
      bucket: bucket_name,
      parentAccessKeyId: Config.github_cache_blob_storage_access_key,
      permission: permission,
      ttlSeconds: ttl
    }
    response = @connection.post(path: path, body: body.to_json, expects: 200)
    data = JSON.parse(response.body)
    [data["result"]["accessKeyId"], data["result"]["secretAccessKey"], data["result"]["sessionToken"]]
  end
end
