# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  add_filter "/spec/"
  coverage_dir "coverage"
  minimum_coverage 100
  minimum_coverage_by_file 100
  enable_coverage :branch
end

require_relative "../lib/proof_extract"

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
