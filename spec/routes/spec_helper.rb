# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !/test\d*\z/.match?(DB.opts[:database])

require "rack/test"
require "argon2"

TEST_USER_EMAIL = "user@example.com"
TEST_USER_PASSWORD = "Secret@Password123"
TEST_LOCATION = "eu-central-h1"

RSpec.configure do |config|
  config.include Rack::Test::Methods

  class RSpec::Matchers::DSL::Matcher
    def self.error_response_matcher(expected_state, expected_message, expected_details, nested_error)
      message_path = nested_error ? ["error", "message"] : ["message"]
      details_path = nested_error ? ["error", "details"] : ["details"]

      match do |response|
        return false if response.body.empty?

        parsed_body = JSON.parse(response.body)

        message_match = case expected_message
        when nil
          true
        when String
          parsed_body.dig(*message_path) == expected_message
        when Regexp
          expected_message.match?(parsed_body.dig(*message_path))
        end

        response.status == expected_state &&
          message_match &&
          (expected_details.nil? || parsed_body.dig(*details_path) == expected_details)
      end

      failure_message do |response|
        parsed_body = response.body.empty? ? {} : JSON.parse(response.body)
        <<~MESSAGE
          #{"expected: ".rjust(16)}#{expected_state}#{expected_message && " - #{expected_message}"}#{expected_details && " - #{expected_details}"}
          #{"got: ".rjust(16)}#{response.status}#{expected_message && " - #{parsed_body.dig(*message_path)}"}#{expected_details && " - #{parsed_body.dig(*details_path)}"}
        MESSAGE
      end
    end
  end

  RSpec::Matchers.define :have_api_error do |expected_state, expected_message, expected_details|
    error_response_matcher(expected_state, expected_message, expected_details, true)
  end

  RSpec::Matchers.define :have_runtime_error do |expected_state, expected_message, expected_details|
    error_response_matcher(expected_state, expected_message, expected_details, false)
  end

  config.include(Module.new do
    def app
      Clover.app
    end

    def last_response
      lr = super

      if lr && !lr.instance_variable_get(:@body_checked)
        lr.instance_variable_set(:@body_checked, true)
        if (match = lr.body.match(/(?<=(.{50}\W))(et[a-z0-9]{24})(?=(\W.{50}))/m))
          unless match[1].match?(/otp_raw_secret|csrf/)
            raise "response body contains TYPE_ETC ubid: #{match.captures.inspect}"
          end
        end
      end

      lr
    end

    def create_account(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD, with_project: true, enable_otp: false, enable_webauthn: false)
      hash = Argon2::Password.new({
        t_cost: 1,
        m_cost: 5,
        secret: Config.clover_session_secret
      }).create(password)

      account = Account.create(email: email, status_id: 2)
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

    def create_private_location(project:)
      loc = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
        project_id: project.id
      )

      LocationCredential.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key"
      ) { it.id = loc.id }
      loc
    end
  end)
end
