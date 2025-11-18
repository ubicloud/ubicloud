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
end
