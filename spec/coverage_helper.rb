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
        path.match?(/\A\/(coverage|rhizome|kubernetes|migrate|ruby_lsp|spec|var|(db|model|loader|\.env)\.rb)/)
      end
    end

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    # Files that exist but were never loaded are discovered by expanding
    # this glob on disk, and every match is stubbed before any filter
    # above runs. So the glob has to skip the vendor/bundle gem tree that
    # CI installs into the repo itself: SimpleCov stubs a file by calling
    # Coverage.line_stub on it, which raises ArgumentError (not the
    # SyntaxError it rescues) for a gem fixture carrying an invalid magic
    # comment, aborting the run after the specs have already passed.
    # vendor's own files are project code, so keep tracking those.
    # Naming directories explicitly would otherwise descend into dot
    # directories, which a leading `**` skips, so drop those too.
    root = File.dirname(__dir__)
    dirs = Dir.children(root).select { !it.start_with?(".") && File.directory?(File.join(root, it)) } - %w[coverage node_modules public vendor]
    track_files "{#{(["*.rb", "vendor/*.rb"] + dirs.map { "#{it}/**/*.rb" }).join(",")}}"
  end
end
