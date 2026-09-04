# frozen_string_literal: true

if ENV["UNUSED_ASSOCIATIONS"]
  require "coverage"
  Coverage.start(methods: true)
  at_exit { Sequel::Model.update_associations_coverage }
elsif (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    coverage :line, minimum: 100 do
      minimum 100, per: :file
    end
    coverage :branch, minimum: 100 do
      minimum 100, per: :file
    end

    command_name "#{suite}#{ENV["TEST_ENV_NUMBER"]}"
    parallel_wait_timeout 600

    if suite == "rhizome"
      skip do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        !path.start_with?("/rhizome/") || !path.include?("/lib/")
      end

      cover "rhizome/**/*.rb"
    else
      skip do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        path.match?(/\A\/(coverage|rhizome|kubernetes|migrate|ruby_lsp|spec|var|(db|model|loader|\.env)\.rb)/) ||
          (file.relevant_lines.zero? && file.no_branches?)
      end

      # Not "**/*.rb": cover parses every matching file on disk before skip
      # filters apply, and gems vendored into vendor/bundle in CI include
      # fixtures that do not parse.
      root = File.dirname(__dir__)
      dir_globs = Dir.children(root).filter_map do |entry|
        "#{entry}/**/*.rb" if entry != "vendor" && !entry.start_with?(".") && File.directory?(File.join(root, entry))
      end
      cover "*.rb", "vendor/*.rb", *dir_globs
    end

    group("Missing") { |src| src.covered_percent < 100 }
    group("Covered") { |src| src.covered_percent == 100 }
  end
end
