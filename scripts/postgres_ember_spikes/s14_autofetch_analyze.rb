#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Summarise s14_autofetch_impact.rb: split each run's pgbench log at the
# moment catch-up finished, into "during catch-up" and "steady state", and
# report per-arm medians and ranges.
#
#   ruby s14_autofetch_analyze.rb [out/s14_autofetch_impact.json]

require "json"

path = ARGV[0] || File.join(__dir__, "out", "s14_autofetch_impact.json")
report = JSON.parse(File.read(path))

def pct(sorted, p)
  return nil if sorted.empty?
  sorted[((sorted.size - 1) * p).round]
end

def window(latencies_us)
  s = latencies_us.sort
  {"n" => s.size, "p50_ms" => pct(s, 0.5)&./(1000.0), "p95_ms" => pct(s, 0.95)&./(1000.0),
   "max_ms" => s.last&./(1000.0)}
end

# pgbench -l: client_id transaction_no latency_us script_no epoch_s epoch_us
def transactions(log)
  File.readlines(log).map do |line|
    f = line.split
    {latency_us: Integer(f[2]), done: Integer(f[4]) + (Integer(f[5]) / 1e6)}
  end
end

report["runs"].each do |run|
  txs = transactions(run["pgbench_log"])
  if run["arm"] == "C" || run["caught_up_epoch"].nil?
    run["windows"] = {"whole" => window(txs.map { _1[:latency_us] })}
  else
    split = run["caught_up_epoch"]
    during, steady = txs.partition { _1[:done] < split }
    run["windows"] = {"during" => window(during.map { _1[:latency_us] }),
                      "steady" => window(steady.map { _1[:latency_us] })}
  end
end

FIELDS = %w[n p50_ms p95_ms max_ms].freeze

def stat(values)
  v = values.compact.sort
  return "-" if v.empty?
  med = v.size.odd? ? v[v.size / 2] : (v[v.size / 2 - 1] + v[v.size / 2]) / 2.0
  format("%.1f [%.1f-%.1f]", med, v.first, v.last)
end

puts "ubiblk: #{report["ubiblk_dir"]}  version: #{report["version_rpc"].inspect}  kernel: #{report["uname_r"]}"
puts "shape: #{report["shape_mbit"] ? "#{report["shape_mbit"]} Mbit/s" : "loopback"}, pgbench #{report["pgbench_seconds"]} s, 1 client"
puts "median [min-max] across runs\n\n"
summary = {}
report["runs"].group_by { _1["arm"] }.sort.each do |arm, runs|
  s = {"runs" => runs.size,
       "pg_ready_ms" => stat(runs.map { _1["pg_ready_ms"] }),
       "first_query_ms" => stat(runs.map { _1["first_query_ms"] }),
       "caught_up_ms" => stat(runs.map { _1["caught_up_ms"] }),
       "fetched_at_first_query" => stat(runs.map { _1.dig("stripes_at_first_query", "fetched") })}
  runs.first["windows"].keys.each do |w|
    FIELDS.each do |k|
      s["#{w}.#{k}"] = stat(runs.map { _1.dig("windows", w, k) })
    end
  end
  summary[arm] = s
  puts "arm #{arm} (#{runs.size} runs)"
  s.each { |k, v| puts format("  %-24s %s", k, v) unless k == "runs" }
  puts
end
report["summary"] = summary
File.write(path.sub(/\.json\z/, "_analyzed.json"), JSON.pretty_generate(report))
