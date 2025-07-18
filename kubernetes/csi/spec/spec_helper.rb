# frozen_string_literal: true

# Start SimpleCov before requiring any application code (only if not disabled)
unless ENV["COVERAGE"] == "false"
  require "simplecov"
  require "simplecov-console"

  SimpleCov.start do
    # Configure formatters for both HTML and console output
    SimpleCov.formatters = [
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::Console
    ]

    # Add filters to exclude test files and generated protobuf files
    add_filter "/spec/"
    add_filter "/bin/"
    add_filter "/test_"
    add_filter "_pb.rb"  # Exclude protobuf generated files

    # Set coverage directory
    coverage_dir "coverage"

    # Configure console formatter
    SimpleCov::Formatter::Console.table_options = {
      max_width: 120,
      sort_by: :covered_percent
    }

    # Set minimum coverage threshold
    minimum_coverage 80
    minimum_coverage_by_file 70

    # Track branches for more detailed coverage
    enable_coverage :branch

    # Add groups for better organization
    add_group "Services", "lib/ubi_csi/*_service.rb"
    add_group "Clients", "lib/ubi_csi/*_client.rb"
    add_group "Core", "lib/ubi_csi.rb"
    add_group "Errors", "lib/ubi_csi/errors.rb"
  end
end

require_relative "../lib/ubi_csi"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on Module and main
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Configure RSpec to be more strict
  config.raise_errors_for_deprecations!
  config.raise_on_warning = true
end
