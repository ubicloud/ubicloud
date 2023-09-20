# frozen_string_literal: true

require "octokit"
require "jwt"
require "yaml"

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

  def self.runner_labels
    @@runner_labels ||= YAML.load_file("config/github_runner_labels.yml").to_h { [_1["name"], _1] }
  end

  def self.failed_deliveries(since)
    client = Github.app_client
    all_deliveries = client.get("/app/hook/deliveries?per_page=100")
    while (next_url = client.last_response.rels[:next]&.href) && (since < all_deliveries.last[:delivered_at])
      all_deliveries += client.get(next_url)
    end

    all_deliveries
      .reject { _1[:delivered_at] < since }
      .group_by { _1[:guid] }
      .values
      .reject { |group| group.any? { _1[:status] == "OK" } }
      .map { |group| group.max_by { _1[:delivered_at] } }
  end

  def self.redeliver_failed_deliveries(since)
    client = Github.app_client
    failed_deliveries = Github.failed_deliveries(since)
    failed_deliveries.each do |delivery|
      Clog.emit("redelivering failed delivery") { {delivery: delivery} }
      client.post("/app/hook/deliveries/#{delivery[:id]}/attempts")
    end
    Clog.emit("redelivered failed deliveries")
  end
end
