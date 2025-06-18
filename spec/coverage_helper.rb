# frozen_string_literal: true

if (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
    minimum_coverage_by_file line: 100, branch: 100

    command_name "#{suite}#{ENV["TEST_ENV_NUMBER"]}"

    if suite == "rhizome"
      require "pathname"
      LOCKED_FILES = ["rhizome/kubernetes/lib/ubi_cni.rb"].map do |file|
        Pathname.new(File.expand_path("..", __dir__)).join(file).to_s
      end

      add_filter do |file|
        !LOCKED_FILES.include?(file.filename)
      end
    else
      add_filter "/rhizome"
      # No need to check coverage for them
      add_filter "/migrate/"
      add_filter "/spec/"
      add_filter "/db.rb"
      add_filter "/model.rb"
      add_filter "/loader.rb"
      add_filter "/.env.rb"
      add_filter "/var/"
    end

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    track_files "**/*.rb"
  end
end
