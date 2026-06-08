# frozen_string_literal: true

if ENV["UNUSED_ASSOCIATIONS"]
  require "coverage"
  Coverage.start(methods: true)
  at_exit { Sequel::Model.update_associations_coverage }
elsif (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
    minimum_coverage_by_file line: 100, branch: 100

    command_name "#{suite}#{ENV["TEST_ENV_NUMBER"]}"

    if suite == "rhizome"
      add_filter do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        !path.start_with?("/rhizome/") || !path.include?("/lib/")
      end
    else
      add_filter do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        path.match?(/\A\/(coverage|rhizome|kubernetes|migrate|spec|var|(db|model|loader|\.env)\.rb)/)
      end
    end

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    track_files "**/*.rb"
  end
end
