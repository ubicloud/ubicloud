# frozen_string_literal: true

require "octokit"
require "jwt"
require "yaml"

Octokit.configure do |c|
  c.connection_options = {
    request: {
      open_timeout: 5,
      timeout: 5
    }
  }
end

module Github
  def self.oauth_client
    Octokit::Client.new(client_id: Config.github_app_client_id, client_secret: Config.github_app_client_secret)
  end

  def self.app_client
    current = Time.now.to_i
    private_key = OpenSSL::PKey::RSA.new(Config.github_app_private_key)
    key = {
      iat: current,
      exp: current + (8 * 60),
      iss: Config.github_app_id
    }
    jwt = JWT.encode(key, private_key, "RS256")

    Octokit::Client.new(bearer_token: jwt)
  end

  def self.installation_client(installation_id)
    access_token = app_client.create_app_installation_access_token(installation_id)[:token]

    client = Octokit::Client.new(access_token: access_token)
    client.auto_paginate = true
    client
  end

  # :nocov:
  def self.freeze
    runner_labels
    super
  end
  # :nocov:

  def self.runner_labels
    @runner_labels ||= begin
      labels = YAML.load_file("config/github_runner_labels.yml").to_h { [it["name"], it] }
      labels.transform_values do |v|
        new = (a = v["alias_for"]) ? labels[a] : v
        new["vm_size"] = "#{new["family"]}-#{new["vcpus"]}"
        Validation.validate_vm_size(new["vm_size"], new["arch"])
        new
      end.freeze
    end
  end

  def self.failed_deliveries(since, max_page = 50)
    client = Github.app_client
    all_deliveries = client.get("/app/hook/deliveries?per_page=100")
    page = 1
    while (next_url = client.last_response.rels[:next]&.href) && (since < all_deliveries.last[:delivered_at])
      if page >= max_page
        Clog.emit("failed deliveries page limit reached") { {deliveries: {max_page: max_page, since: since}} }
        break
      end
      page += 1
      all_deliveries += client.get(next_url)
    end

    Clog.emit("fetched deliveries") { {deliveries: {total: all_deliveries.count, page: page, since: since}} }

    all_deliveries
      .reject { it[:delivered_at] < since }
      .group_by { it[:guid] }
      .values
      .reject { |group| group.any? { it[:status] == "OK" } }
      .map { |group| group.max_by { it[:delivered_at] } }
  end

  def self.redeliver_failed_deliveries(*)
    client = Github.app_client
    failed_deliveries = Github.failed_deliveries(*)
    failed_deliveries.each do |delivery|
      Clog.emit("redelivering failed delivery") { {delivery: delivery.to_h} }
      client.post("/app/hook/deliveries/#{delivery[:id]}/attempts")
    end
    Clog.emit("redelivered failed deliveries") { {deliveries: {failed: failed_deliveries.count}} }
    failed_deliveries
  end
end
