# frozen_string_literal: true

require "open3"
require "tmpdir"

module ShellScriptHelper
  Result = Struct.new(:out, :err, :status, :calls)

  # Each stub logs its name and arguments to calls, then runs its body.
  # /bin/sh scripts run under dash as in production and under bash for
  # coverage, both runs must match
  def run_script(path, *args, stubs: {})
    script = File.expand_path("../../#{path}", __dir__)
    shells = File.open(script, &:readline).start_with?("#!/bin/sh") ? %w[dash bash] : %w[bash]
    Dir.mktmpdir do |bin|
      calls = File.join(bin, "calls")
      stubs.each do |name, body|
        File.write(File.join(bin, name), "#!/bin/sh\necho \"#{name} $*\" >> #{calls}\n#{body}\n", perm: 0o755)
      end

      results = shells.map do |shell|
        File.write(calls, "")
        out, err, status = Open3.capture3({"PATH" => "#{bin}:#{ENV["PATH"]}"}, shell, script, *args)
        Result.new(out, err, status.exitstatus, File.read(calls))
      end
      expect(results).to all(eq(results.first))
      results.first
    end
  end
end
