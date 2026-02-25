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
  def self.generate_temp_credentials(bucket:, permission:, ttl_seconds: 86400)
    api_token = Config.cloudflare_r2_api_token
    account_id = Config.cloudflare_account_id

    conn = Excon.new("https://api.cloudflare.com", headers: {
      "Authorization" => "Bearer #{api_token}",
      "Content-Type" => "application/json"
    })

    response = conn.post(
      path: "/client/v4/accounts/#{account_id}/r2/temp-access-credentials",
      body: {
        bucket: bucket,
        parentAccessKeyId: parent_access_key_id(api_token),
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

  # The R2 parent access key ID is the API token's ID. We derive it by
  # calling the token-verify endpoint and cache the result for the process
  # lifetime.
  def self.parent_access_key_id(api_token)
    @parent_access_key_id ||= begin
      response = Excon.get(
        "https://api.cloudflare.com/client/v4/user/tokens/verify",
        headers: {"Authorization" => "Bearer #{api_token}"},
        expects: 200
      )
      JSON.parse(response.body).dig("result", "id")
    end
  end
end
