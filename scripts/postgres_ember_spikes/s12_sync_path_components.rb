#!/usr/bin/env ruby
# frozen_string_literal: true

#
# The three pieces of the synchronous create path (design doc 7.2) that the
# API-level benchmark in s11 cannot see:
#
#   1. the HTTPS call to emberd, fresh connection vs the keep-alive pool the
#      design specifies for `lib/ember_host_client.rb`
#   2. what it costs to hold the DB transaction open across that call, which is
#      what `DB.transaction { ... FOR UPDATE ... host call }` does
#   3. the placement query
#
# Run from the repo root so the control-plane environment is available:
#   EMBERD=https://<host>:8452 ruby scripts/postgres_ember_spikes/s12_sync_path_components.rb

require_relative "../../loader"
require "json"
require "jwt"
require "net/http"
require "uri"

EMBERD = URI(ENV["EMBERD"] || "https://127.0.0.1:8452")
SECRET = "spike-host-secret"

def percentile(sorted, p)
  return 0.0 if sorted.empty?
  sorted[((sorted.length - 1) * p / 100.0).round]
end

def ms(t0)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
end

def summarize(label, samples)
  s = samples.sort
  format("  %-46s n=%-4d p50=%7.2f  p90=%7.2f  p99=%7.2f",
    label, s.length, percentile(s, 50), percentile(s, 90), percentile(s, 99))
end

def jwt_token
  JWT.encode({host: "vh123", iat: Time.now.to_i, exp: Time.now.to_i + 60}, SECRET, "HS256")
end

def emberd_http
  http = Net::HTTP.new(EMBERD.host, EMBERD.port)
  http.use_ssl = true
  # The design pins the host certificate by fingerprint rather than using a CA.
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  http.keep_alive_timeout = 60
  http.start
  http
end

def emberd_post(http, delay_ms = 0)
  req = Net::HTTP::Post.new("/v1/embers?delay_ms=#{delay_ms}")
  req["Authorization"] = "Bearer #{jwt_token}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate({"ember_id" => "ember123", "generation" => 1})
  http.request(req)
end

report = {}

puts "== 1. HTTPS call to emberd (#{EMBERD}) =="
fresh = []
50.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  http = emberd_http
  emberd_post(http)
  fresh << ms(t0)
  http.finish
end
puts summarize("fresh connection (TLS handshake each time)", fresh)

http = emberd_http
emberd_post(http)
kept = []
200.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  emberd_post(http)
  kept << ms(t0)
end
http.finish
puts summarize("keep-alive connection (as designed)", kept)
jwt_only = []
1000.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  jwt_token
  jwt_only << ms(t0)
end
puts summarize("of which: minting the HS256 JWT", jwt_only)
report["emberd_fresh"] = percentile(fresh.sort, 50)
report["emberd_keepalive"] = percentile(kept.sort, 50)
report["jwt_mint"] = percentile(jwt_only.sort, 50)

puts "\n== 2. holding the transaction across the host call =="
puts "   DB.transaction { SELECT ... FOR UPDATE; <host call takes N ms> }"

# A scratch table so each worker can lock its own row, which is what concurrent
# creates of *different* embers do. Locking one shared row models concurrent
# resumes of the *same* ember, which the design intends to serialise.
DB.run("CREATE TABLE IF NOT EXISTS ember_lock_spike (id integer PRIMARY KEY)")
DB.run("INSERT INTO ember_lock_spike SELECT generate_series(0, 199) ON CONFLICT DO NOTHING")

def hold_bench(pool:, hold_ms:, concurrency:, per_thread:, shared_row:)
  db = Sequel.connect(Config.clover_database_url, max_connections: pool, pool_timeout: 30)
  samples = []
  timeouts = 0
  mutex = Mutex.new
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = Array.new(concurrency) do |t|
    Thread.new do
      local = []
      local_timeouts = 0
      per_thread.times do |i|
        row = shared_row ? 0 : (t * per_thread + i) % 200
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          db.transaction do
            db[:ember_lock_spike].where(id: row).for_update.first
            sleep(hold_ms / 1000.0)
          end
          local << ms(t0)
        rescue Sequel::PoolTimeout
          local_timeouts += 1
        end
      end
      mutex.synchronize do
        samples.concat(local)
        timeouts += local_timeouts
      end
    end
  end
  threads.each(&:join)
  wall = ms(started)
  db.disconnect
  {samples: samples.sort, timeouts:,
   throughput: (samples.length / (wall / 1000.0)).round(1)}
end

results = {}
puts "   independent embers (each locks its own row):"
[[4, 50], [4, 500], [15, 50], [15, 500], [40, 500]].each do |pool, hold_ms|
  r = hold_bench(pool:, hold_ms:, concurrency: 20, per_thread: 5, shared_row: false)
  puts format("     pool=%-3d host call=%-4d ms  20 concurrent -> p50=%8.1f  p99=%8.1f  %6.1f req/s  timeouts=%d",
    pool, hold_ms, percentile(r[:samples], 50), percentile(r[:samples], 99), r[:throughput], r[:timeouts])
  results["indep_pool#{pool}_hold#{hold_ms}"] = {"p50" => percentile(r[:samples], 50),
                                                 "throughput" => r[:throughput], "timeouts" => r[:timeouts]}
end
puts "   same ember (all lock one row, as concurrent resumes would):"
[[40, 50], [40, 500]].each do |pool, hold_ms|
  r = hold_bench(pool:, hold_ms:, concurrency: 20, per_thread: 5, shared_row: true)
  puts format("     pool=%-3d host call=%-4d ms  20 concurrent -> p50=%8.1f  p99=%8.1f  %6.1f req/s",
    pool, hold_ms, percentile(r[:samples], 50), percentile(r[:samples], 99), r[:throughput])
  results["shared_pool#{pool}_hold#{hold_ms}"] = {"p50" => percentile(r[:samples], 50),
                                                  "throughput" => r[:throughput]}
end
DB.run("DROP TABLE IF EXISTS ember_lock_spike")
report["transaction_hold"] = results

puts "\n== 3. placement query =="
# Shaped like the design's: hosts in a location, healthy, ordered by capacity.
place = []
200.times do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  VmHost
    .where(allocation_state: "accepting")
    .where(Sequel[:vm_host][:location_id] => Location::HETZNER_FSN1_ID)
    .order(Sequel.desc(:total_cores))
    .limit(3)
    .all
  place << ms(t0)
end
puts summarize("VmHost placement-shaped query", place)
report["placement_query"] = percentile(place.sort, 50)

File.write(File.join(__dir__, "out", "s12_sync_path_components.json"), JSON.pretty_generate(report))
puts "\nwrote out/s12_sync_path_components.json"
