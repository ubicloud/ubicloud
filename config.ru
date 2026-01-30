# frozen_string_literal: true

ENV["PROCESS_TYPE"] = "web"

require_relative "loader"

CONNECTION_CHECKOUT_TELEMETRY = ConnectionCheckoutTelemetry.new
CONNECTION_CHECKOUT_TELEMETRY.setup

clover_freeze

app = if Config.development?
  backtrace_filter = %r{\A#{Regexp.escape(Dir.pwd)}/(?!spec/)}
  lambda do |env|
    DB.detect_duplicate_queries(backtrace_filter:, warn: true) do
      Unreloader.call(env)
    end
  end
else
  Clover.app
end

run(app)

Tilt.finalize! unless Config.development?
