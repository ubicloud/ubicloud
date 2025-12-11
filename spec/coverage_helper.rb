# frozen_string_literal: true

if (suite = ENV.delete("COVERAGE"))
  require "simplecov"
  require "simplecov-console"

  # Configure console formatter to show uncovered files with line/branch details
  SimpleCov::Formatter::Console.max_rows = -1  # Show all uncovered files
  SimpleCov::Formatter::Console.show_covered = false  # Only show files with gaps
  SimpleCov::Formatter::Console.output_style = "table"
  SimpleCov::Formatter::Console.output_to_file = true  # Save to file for AI/headless review
  SimpleCov::Formatter::Console.output_filename = "console_report.txt"  # Relative to coverage dir

  SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::Console
  ])

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
      add_filter do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        path.match?(/\A\/(coverage|rhizome|kubernetes|migrate|spec|var|vendor|(db|model|loader|\.env)\.rb)/)
      end
    end

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    track_files "**/*.rb"
  end
end
