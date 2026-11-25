# frozen_string_literal: true

if ENV["UNUSED_ASSOCIATIONS"]
  require "coverage"
  Coverage.start(methods: true)
  at_exit do
    # Parallel spec processes merge their results into the same coverage
    # file, so take a lock to keep them from overwriting each other
    File.open(__FILE__) do |file|
      file.flock(File::LOCK_EX)
      Sequel::Model.update_associations_coverage
    end
  end
elsif (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  shell_scripts = Set.new

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
        !path.start_with?("/rhizome/") || !(path.include?("/lib/") || shell_scripts.include?(file.filename))
      end

      cover "rhizome/**/*.rb"
      cover { |file| shell_scripts.include?(file.filename) }
    else
      skip do |file|
        path = file.filename.delete_prefix(File.dirname(__dir__))
        path.match?(/\A\/(rhizome|kubernetes|migrate|ruby_lsp|spec|var|(db|model|loader|\.env)\.rb)/) ||
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

  if suite == "rhizome"
    # Line coverage for rhizome shell scripts run by specs, from bash xtrace.
    # Debian dash lacks LINENO, so specs run /bin/sh scripts under bash too
    xtrace_dir = File.join(File.dirname(__dir__), "coverage", "xtrace")
    FileUtils.mkdir_p(xtrace_dir)
    xtrace_log = File.join(xtrace_dir, "log")
    File.write(xtrace_log, "")
    ENV["BASH_ENV"] = File.join(xtrace_dir, "env")
    File.write(ENV["BASH_ENV"], <<~SH)
      exec 222>>#{xtrace_log}
      BASH_XTRACEFD=222
      PS4='+@COV@${BASH_SOURCE}:${LINENO}@'
      set -x
    SH

    shell_coverage = lambda do
      hits = Hash.new { |h, path| h[path] = Hash.new(0) }
      File.read(xtrace_log).scan(%r{^\++@COV@(#{Regexp.escape(File.dirname(__dir__))}/rhizome/[^:\n]+):(\d+)@}) do |path, line|
        hits[path][Integer(line, 10)] += 1
      end

      hits.to_h do |path, line_hits|
        heredoc = nil
        continued = false
        lines = File.readlines(path).map.with_index(1) do |source, lineno|
          line = source.strip
          code = !heredoc && !continued && !line.empty? && !line.start_with?("#") &&
            # Keywords, function headers, case patterns
            !line.sub(/\s+#.*/, "").match?(/\A(then|else|fi|do|done|esac|;;|[{}()]|\w+\(\) *[{(]|[^()]+\))\z/)
          heredoc = (line == heredoc) ? nil : heredoc || line[/(?<!<)<<(?!<)-?\s*(['"]?)(\w+)\1/, 2]
          continued = line.end_with?("\\")
          hit = line_hits[lineno]
          hit.positive? ? hit : (0 if code)
        end
        shell_scripts << path
        [path, {lines:, branches: {}}]
      end
    end

    Coverage.singleton_class.prepend(Module.new do
      define_method(:result) { |**kwargs| super(**kwargs).merge(shell_coverage.call) }
    end)
  end
end
