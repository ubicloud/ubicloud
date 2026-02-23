# frozen_string_literal: true

require "excon"
require "json"

module CloudflareR2
  # Generate temporary R2 credentials scoped to a specific bucket/prefix.
  # Uses Cloudflare's temp-access-credentials API.
  #
  # permission: "object-read-only" for VM boot, "object-read-write" for archive/delete
  #
  # Returns a hash with :access_key_id, :secret_access_key, :session_token
  def self.create_temporary_credentials(bucket:, prefix: nil, permission: "object-read-only", ttl_seconds: 3600)
    account_id = Config.cloudflare_account_id
    api_token = Config.cloudflare_r2_api_token
    parent_key_id = Config.cloudflare_r2_parent_access_key_id

    body = {
      "bucket" => bucket,
      "parentAccessKeyId" => parent_key_id,
      "permission" => permission,
      "ttlSeconds" => ttl_seconds
    }
    body["prefix"] = prefix if prefix

    connection = Excon.new("https://api.cloudflare.com")
    response = connection.post(
      path: "/client/v4/accounts/#{account_id}/r2/temp-access-credentials",
      headers: {
        "Authorization" => "Bearer #{api_token}",
        "Content-Type" => "application/json"
      },
      body: body.to_json,
      expects: 200
    )

    result = JSON.parse(response.body)
    unless result["success"]
      errors = result["errors"]&.map { |e| e["message"] }&.join(", ")
      raise "Cloudflare R2 temp credentials failed: #{errors}"
    end

    creds = result["result"]
    {
      access_key_id: creds["accessKeyId"],
      secret_access_key: creds["secretAccessKey"],
      session_token: creds["sessionToken"]
    }
  end
end
