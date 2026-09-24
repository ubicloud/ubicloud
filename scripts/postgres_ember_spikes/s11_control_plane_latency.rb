#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Is the control plane's synchronous create/resume path (design doc 7.2)
# actually cheap enough to run inside the API request?
#
# The design budgets 15 ms for "API, DB, placement" and 10 ms for the HTTPS call
# to emberd, which together have to fit under a 150 ms warm-pool create. None
# of that was ever measured. This measures the pieces that already exist: the
# full Clover request path through Puma, a create-shaped endpoint that opens a
# transaction and writes rows, and the same under concurrency.
#
#   BASE=http://127.0.0.1:3000 TOKEN=pat-... PROJECT=pj... ruby s11_control_plane_latency.rb

require "json"
require "net/http"
require "securerandom"
require "uri"

BASE = URI(ENV["BASE"] || "http://127.0.0.1:3000")
TOKEN = ENV.fetch("TOKEN")
PROJECT = ENV.fetch("PROJECT")
LOCATION = ENV["LOCATION"] || "eu-central-h1"
HOST_HEADER = ENV["HOST_HEADER"] || "api.localhost"

def percentile(sorted, p)
  return nil if sorted.empty?
  sorted[((sorted.length - 1) * p / 100.0).round]
end

def stats(label, samples, errors = 0)
  s = samples.sort
  format("%-38s n=%-4d err=%-3d p50=%7.1f  p90=%7.1f  p99=%7.1f  max=%7.1f",
    label, s.length, errors, percentile(s, 50).to_f, percentile(s, 90).to_f,
    percentile(s, 99).to_f, s.last.to_f)
end

def new_http
  http = Net::HTTP.new(BASE.host, BASE.port)
  http.use_ssl = BASE.scheme == "https"
  http.keep_alive_timeout = 30
  http.start
  http
end

def request(http, method, path, body = nil)
  klass = (method == :post) ? Net::HTTP::Post : Net::HTTP::Get
  req = klass.new(path)
  req["Host"] = HOST_HEADER
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Accept"] = "application/json"
  if body
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body)
  end
  http.request(req)
end

# Run `n` requests spread over `concurrency` threads; each thread keeps one
# connection, which is what a real client pool does.
def bench(label, n:, concurrency:, warmup: 5)
  samples = []
  errors = 0
  mutex = Mutex.new

  http = new_http
  warmup.times { yield(http, -1) }
  http.finish

  threads = Array.new(concurrency) do |t|
    Thread.new do
      conn = new_http
      local = []
      local_errors = 0
      (n / concurrency).times do |i|
        idx = t * 10_000 + i
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          res = yield(conn, idx)
          local_errors += 1 unless res.is_a?(Net::HTTPSuccess)
        rescue => e
          local_errors += 1
          warn "  #{label}: #{e.class}: #{e.message}" if local_errors < 3
        end
        local << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
      end
      conn.finish
      mutex.synchronize do
        samples.concat(local)
        errors += local_errors
      end
    end
  end
  threads.each(&:join)
  puts "  " + stats(label, samples, errors)
  {"p50" => percentile(samples.sort, 50), "p90" => percentile(samples.sort, 90),
   "p99" => percentile(samples.sort, 99), "errors" => errors}
end

report = {"base" => BASE.to_s, "mode" => ENV["MODE"] || "unknown"}
run = SecureRandom.hex(3)

puts "== single client =="
report["get_project"] = bench("GET /project (auth + 1 row)", n: 100, concurrency: 1) do |http, _|
  request(http, :get, "/project")
end
report["list_firewall"] = bench("GET firewall list (authz dataset)", n: 100, concurrency: 1) do |http, _|
  request(http, :get, "/project/#{PROJECT}/location/#{LOCATION}/firewall")
end
report["create_firewall"] = bench("POST firewall (txn + insert + audit)", n: 100, concurrency: 1) do |http, i|
  request(http, :post, "/project/#{PROJECT}/location/#{LOCATION}/firewall/s#{run}a#{i}", {"description" => "spike"})
end

puts "== concurrency (the API request thread is where create would run) =="
[2, 5, 10, 15, 30].each do |c|
  report["create_c#{c}"] = bench("POST firewall, #{c} clients", n: c * 20, concurrency: c) do |http, i|
    request(http, :post, "/project/#{PROJECT}/location/#{LOCATION}/firewall/s#{run}c#{c}x#{i}", {"description" => "spike"})
  end
end
[15, 30].each do |c|
  report["get_c#{c}"] = bench("GET /project, #{c} clients", n: c * 20, concurrency: c) do |http, _|
    request(http, :get, "/project")
  end
end

File.write(File.join(__dir__, "out", "s11_control_plane_#{report["mode"]}.json"), JSON.pretty_generate(report))
puts "\nwrote out/s11_control_plane_#{report["mode"]}.json"
