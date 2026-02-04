# frozen_string_literal: true

ENV["PROCESS_TYPE"] = "web"

require_relative "loader"

# We start the thread to monitor checkout events in puma's before_worker_boot
# hook, but that is not called if puma is not running in forking mode. While
# there are other ways besides WEB_CONCURRENCY to turn on forking mode, using
# WEB_CONCURRENCY is how we enable forking in production and staging. Only
# setup connection checkout telemetry if WEB_CONCURRENCY is used, to avoid a
# memory leak in development environments that do not set WEB_CONCURRENCY.
if ENV["WEB_CONCURRENCY"]
  CONNECTION_CHECKOUT_TELEMETRY = ConnectionCheckoutTelemetry.new
  CONNECTION_CHECKOUT_TELEMETRY.setup
else
  CONNECTION_CHECKOUT_TELEMETRY = nil
end

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
