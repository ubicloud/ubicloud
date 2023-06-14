# frozen_string_literal: true

if (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 92.5, branch: 90.5
    minimum_coverage_by_file line: 11, branch: 0

    command_name suite

    add_filter "/spec/"
    add_filter "/model.rb"
    add_filter "/db.rb"
    add_filter "/.env.rb"
    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }
  end
end
