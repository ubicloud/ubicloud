# frozen_string_literal: true

require_relative "../spec_helper"

require "rack/test"
require "argon2"

RSpec.configure do |config|
  include Rack::Test::Methods

  def app
    Clover.freeze.app
  end
end

def login_api(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
  post "/api/login?login=#{email}&password=#{password}", nil, {"CONTENT_TYPE" => "application/json"}
  expect(last_response.status).to eq(200)
  header "Authorization", "Bearer #{last_response.headers["authorization"]}"
end
