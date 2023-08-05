# frozen_string_literal: true

if (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 97.8, branch: 98.9
    minimum_coverage_by_file line: 0, branch: 81.25

    command_name suite

    # rhizome (dataplane) and controlplane should have separate coverage reports.
    # They will have different coverage suites in future.
    add_filter "/rhizome"

    # No need to check coverage for them
    add_filter "/migrate/"
    add_filter "/spec/"
    add_filter "/db.rb"
    add_filter "/model.rb"
    add_filter "/loader.rb"
    add_filter "/.env.rb"

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    track_files "**/*.rb"
  end
end
