# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.before {
    allow(Config).to receive(:postgres_gateway_token_secret).and_return(Config.clover_session_secret)
  }

  config.include(Module.new do
    def login_gateway
      token = JWT.encode({iss: "postgres-gateway", iat: Time.now.to_i, exp: Time.now.to_i + 60},
        Config.postgres_gateway_token_secret, "HS256")
      header "Authorization", "Bearer #{token}"
    end
  end)
end
