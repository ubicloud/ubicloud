# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  def login_api(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD, use_pat: true)
    if use_pat
      account = Account[email: email]
      @pat = account.api_keys.first || ApiKey.create_personal_access_token(account)
      header "Authorization", "Bearer pat-#{@pat.ubid}-#{@pat.key}"
    else
      post "/login", JSON.generate(login: email, password: password), {"CONTENT_TYPE" => "application/json"}
      expect(last_response.status).to eq(200)
      header "Authorization", "Bearer #{last_response.headers["authorization"]}"
    end
  end

  def project_with_default_policy(account, name: "project-1")
    project = account.create_project_with_default_policy(name)

    if @pat
      @pat.associate_with_project(project)
      Authorization::ManagedPolicy::Admin.apply(project, [@pat], append: true)
    end

    project
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
