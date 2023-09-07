# frozen_string_literal: true

require "octokit"
require "jwt"

module Github
  def self.oauth_client
    Octokit::Client.new(client_id: Config.github_app_client_id, client_secret: Config.github_app_client_secret)
  end

  def self.app_client
    current = Time.now.to_i
    private_key = OpenSSL::PKey::RSA.new(Config.github_app_private_key)
    key = {
      iat: current,
      exp: current + (10 * 60),
      iss: Config.github_app_id
    }
    jwt = JWT.encode(key, private_key, "RS256")

    Octokit::Client.new(bearer_token: jwt)
  end

  def self.installation_client(installation_id)
    access_token = app_client.create_app_installation_access_token(installation_id)[:token]

    Octokit::Client.new(access_token: access_token)
  end
end
