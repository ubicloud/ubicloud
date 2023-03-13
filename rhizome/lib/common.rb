# frozen_string_literal: true

require "bundler/setup"
require "shellwords"

def r(commandline)
  out = `#{commandline}`
  fail "command failed" unless $?.success?
  out
end
