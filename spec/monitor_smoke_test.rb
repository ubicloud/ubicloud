# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "json"
require_relative "../ubid"

output_filename = "spec/monitor-smoke-test-output-"

fd_map = lambda do |i|
  {:in => :close, [:out, :err] => "#{output_filename}#{i}"}
end

monitor_pids = [
  Process.spawn({"DYNO" => "monitor.2"}, "bin/monitor", **fd_map.call(0)),
  Process.spawn({"PS" => "monitor.3"}, "bin/monitor", **fd_map.call(1)),
  Process.spawn("bin/monitor", "4", **fd_map.call(2)),
  Process.spawn("bin/monitor", **fd_map.call(3))
]

print("monitor smoke test: ")
10.times do
  print "."
  sleep 1
end
puts "finished, shutting down processes"

Process.kill(:TERM, *monitor_pids)
clean = nil
Thread.new do
  monitor_pids.each do
    Process.waitpid(it)
    clean = false unless $?.success?
  end
  clean = true if clean.nil?
end.join(3)

unless clean
  warn "Not all monitor processes shutdown cleanly within 3 seconds"
  exit 1
end

required_ranges = [
  ["00000000-0000-0000-0000-000000000000", "40000000-0000-0000-0000-000000000000"], # 1/4
  ["40000000-0000-0000-0000-000000000000", "80000000-0000-0000-0000-000000000000"], # 2/4
  ["80000000-0000-0000-0000-000000000000", "c0000000-0000-0000-0000-000000000000"], # 3/4
  ["c0000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"]  # 4/4
]
possible_ranges = required_ranges + [
  ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"], # 1/1
  ["00000000-0000-0000-0000-000000000000", "55555555-0000-0000-0000-000000000000"], # 1/3
  ["00000000-0000-0000-0000-000000000000", "80000000-0000-0000-0000-000000000000"], # 1/2
  ["55555555-0000-0000-0000-000000000000", "aaaaaaaa-0000-0000-0000-000000000000"], # 2/3
  ["80000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"], # 2/2
  ["aaaaaaaa-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"]  # 3/3
]

output_filenames = Array.new(4) { |i| "#{output_filename}#{i}" }
output = output_filenames.map { File.read(it) }.join
ranges = output.scan(/"range":"([-0-9a-f]+)\.\.\.?([-0-9a-f]+)"/)
ranges.each do
  next if possible_ranges.include?(it)
  warn "unexpected monitor repartition range: #{it}"
  exit 1
end
unless ranges.length.between?(4, 10)
  warn "unexpected number of monitor repartitions (should be 4-10): #{ranges.length}"
  warn output
  exit 1
end
unless (missing_ranges = required_ranges - ranges).empty?
  warn "not all required monitor repartition ranges present: #{missing_ranges}"
  exit 1
end

up, down, evloop, mc2 = resources = %w[vp down evloop mc2].map { UBID.generate_vanity("et", "mr", it).to_s }

lines = {}
output.split("\n").each do |line|
  next if line.include?("monitor_repartition")
  resource = resources.find { line.include?(it) } || :other
  begin
    data = JSON.parse(line)
  rescue JSON::ParserError
    warn "Unexpected/non-JSON monitor output line:"
    warn line
    warn ""
    warn "Full output:"
    warn output
    raise
  end
  data.delete("time")
  (lines[resource] ||= []) << data
end
lines.each_value(&:uniq!).each_value { it.sort_by!(&:inspect) }

{
  up => ["up", 1],
  evloop => ["up", 1],
  mc2 => ["up", 2],
  down => ["down", 1]
}.each do |r, (reading, count)|
  expected_lines = Array.new(lines[r].size - 1) do
    {"got_pulse" => {"ubid" => r, "pulse" => {"reading" => reading, "reading_rpt" => it + 1}}, "message" => "Got new pulse."}
  end
  expected_lines << {"metrics_export_success" => {"ubid" => r, "count" => count}, "message" => "Metrics export has finished."}
  unless lines[r] == expected_lines
    warn "unexpected lines for #{r}: #{lines[r]}"
    exit 1
  end
end

unless lines[:other].flat_map(&:keys).uniq.sort == ["message", "monitor_metrics"]
  warn "unexpected other lines: #{lines[:other]}"
  exit 1
end

puts "all checks passed!"
output_filenames.each { File.delete(it) }
