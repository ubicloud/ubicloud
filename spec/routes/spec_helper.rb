# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !/test\d*\z/.match?(DB.opts[:database])

require "rack/test"
require "argon2"

TEST_USER_EMAIL = "user@example.com"
TEST_USER_PASSWORD = "Secret@Password123"
TEST_LOCATION = "eu-central-h1"

RSpec.configure do |config|
  include Rack::Test::Methods

  def app
    Clover.app
  end

  RSpec::Matchers.define :have_api_error do |expected_state, expected_message, expected_details|
    match do |response|
      parsed_body = JSON.parse(response.body)
      response.status == expected_state &&
        (expected_message.nil? || parsed_body.dig("error", "message") == expected_message) &&
        (expected_details.nil? || parsed_body.dig("error", "details") == expected_details)
    end

    failure_message do |response|
      parsed_body = JSON.parse(response.body)
      <<~MESSAGE
        #{"expected: ".rjust(16)}#{expected_state}#{expected_message && " - #{expected_message}"}#{expected_details && " - #{expected_details}"}
        #{"got: ".rjust(16)}#{response.status}#{expected_message && " - #{parsed_body.dig("error", "message")}"}#{expected_details && " - #{parsed_body.dig("error", "details")}"}
      MESSAGE
    end
  end
end

def create_account(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD, with_project: true, enable_otp: false, enable_webauthn: false)
  hash = Argon2::Password.new({
    t_cost: 1,
    m_cost: 5,
    secret: Config.clover_session_secret
  }).create(password)

  account = Account.create_with_id(email: email, status_id: 2)
  DB[:account_password_hashes].insert(id: account.id, password_hash: hash)
  if enable_otp
    DB[:account_otp_keys].insert(id: account.id, key: "oth555fnbrrfbi3nu2gksjxh63n2xofh")
  end
  if enable_webauthn
    DB[:account_webauthn_keys].insert(account_id: account.id, webauthn_id: "mKH7k5", public_key: "public-key", sign_count: 1, name: "test_key")
  end

  account.create_project_with_default_policy("Default") if with_project
  account
end
