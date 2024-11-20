# frozen_string_literal: true

require_relative "../spec_helper"

def login_api(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
  post "/login", JSON.generate(login: email, password: password), {"CONTENT_TYPE" => "application/json"}
  expect(last_response.status).to eq(200)
  header "Authorization", "Bearer #{last_response.headers["authorization"]}"
end

RSpec.configure do |config|
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
