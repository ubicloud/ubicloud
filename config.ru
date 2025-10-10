# frozen_string_literal: true

require_relative "loader"

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
