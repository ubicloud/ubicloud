# frozen_string_literal: true

require "excon"
require "json"

class CloudflareR2
  # Generate temporary S3 credentials scoped to a specific bucket.
  #
  # permission: "object-read-only" or "object-read-write"
  # ttl_seconds: credential validity in seconds (max 604800 = 7 days)
  #
  # Returns a hash with :access_key_id, :secret_access_key, :session_token
  def self.generate_temp_credentials(bucket:, permission:, ttl_seconds:)
    api_token = Config.machine_image_r2_api_token
    account_id = Config.machine_image_r2_account_id
    parent_access_key_id = Config.machine_image_r2_access_key_id

    conn = Excon.new("https://api.cloudflare.com", headers: {
      "Authorization" => "Bearer #{api_token}",
      "Content-Type" => "application/json"
    })

    response = conn.post(
      path: "/client/v4/accounts/#{account_id}/r2/temp-access-credentials",
      body: {
        bucket: bucket,
        parentAccessKeyId: parent_access_key_id,
        permission: permission,
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
end
