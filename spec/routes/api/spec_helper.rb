# frozen_string_literal: true

require_relative "../spec_helper"

def login_api(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
  post "/api/login", JSON.generate(login: email, password: password), {"CONTENT_TYPE" => "application/json"}
  expect(last_response.status).to eq(200)
  header "Authorization", "Bearer #{last_response.headers["authorization"]}"
end
