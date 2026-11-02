# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"

  SimpleCov.start do
    coverage :line, minimum: 100 do
      minimum 100, per: :file
    end
    coverage :branch, minimum: 100 do
      minimum 100, per: :file
    end

    root File.expand_path("../..", __dir__)
    coverage_dir "coverage/terraform"
    cover "terraform/lib/**/*.rb"

    group("Missing") { |src| src.covered_percent < 100 }
    group("Covered") { |src| src.covered_percent == 100 }
  end
end

require "json"
require_relative "../lib/terraform_generator"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random

  config.include(Module.new do
    # Specs write the document with symbol keys; the round trip through JSON
    # gives it the string keys that YAML would.
    def openapi(paths:, **components)
      JSON.parse(JSON.generate({paths:, components:}))
    end
  end)
end
