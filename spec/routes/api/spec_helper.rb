# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  def login_api(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD, use_pat: true)
    if use_pat
      account = Account[email: email]
      unless (pat = account.api_keys.first)
        pat = ApiKey.create_with_id(owner_table: "accounts", owner_id: account.id, used_for: "api")
      end
      header "Authorization", "Bearer pat-#{pat.ubid}-#{pat.key}"
    else
      post "/login", JSON.generate(login: email, password: password), {"CONTENT_TYPE" => "application/json"}
      expect(last_response.status).to eq(200)
      header "Authorization", "Bearer #{last_response.headers["authorization"]}"
    end
  end

  def project_with_default_policy(account, name: "project-1")
    account.create_project_with_default_policy(name)
  end

  config.define_derived_metadata(file_path: %r{\A\./spec/routes/api/}) do |metadata|
    metadata[:clover_api] = true
  end

  config.before do |example|
    next unless example.metadata[:clover_api]
    header "Host", "api.ubicloud.com"
    header "Content-Type", "application/json"
    header "Accept", "application/json"
  end
end
