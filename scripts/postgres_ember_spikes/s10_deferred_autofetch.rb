#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Resume on another host with catch-up deferred until the ember is serving.
#
# Resuming a volume from a remote source has two goals that fight each other:
# hand the tenant a working database as fast as possible, and stop depending on
# the source host. Fetching 1.5 GiB in the background while PostgreSQL is
# starting costs ~430 ms of the tenant's latency. The `start_autofetch` RPC
# on ubiblk's start-autofetch-rpc branch lets the control plane sequence them:
# resume with autofetch off, serve the first query, then catch up.
#
#   ruby s10_deferred_autofetch.rb [template] [mb_of_data]
#
# IDLE=1 sends no queries once catch-up is requested, only polls status, which
# reads shared state without waking ubiblk's background worker: the case of a
# ember resumed by one query and then left alone. IDLE_TIMEOUT (seconds, 60 by
# default) is how long to wait before calling it stalled.

require_relative "lib/ember"

template = ARGV[0] || "t512"
data_mb = Integer(ARGV[1] || 200)
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_B_ROOT = "/var/storage/detachable-hostb"
PASSWORD = "ember-#{SecureRandom.hex(8)}"
PORT = 5505

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(HOST_B_ROOT)
slot_a = Spike::Slot.new(200).create
slot_b = Spike::Slot.new(201).create

def psql(slot, sql, timeout: 120)
  Spike.sh("timeout", "-s", "KILL", timeout.to_s, "ip", "netns", "exec", slot.netns,
    "env", "PGPASSWORD=#{PASSWORD}", "PGCONNECT_TIMEOUT=30", "psql", "-h", Spike::GUEST_IP6,
    "-U", "postgres", "-d", "postgres", "-tAqX", "-c", sql).strip
end

def bring_up(slot, vol, template_dir)
  t = Spike.now
  vol.start
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 60)
  vm.wait_state("Running", timeout: 60)
  vm.agent.wait_ready(timeout: 60)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  vm.agent.call("attach", device: "cldata", mount: "/data", timeout_s: 60)
  vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 180)
  [vm, Spike.ms(t)]
end

def stripes(vol)
  vol.rpc("status").dig("status", "stripes")
rescue
  nil
end

report = {"ubiblk" => Spike::UBIBLK_DIR}
vm = nil
vol_a = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
vol_b = nil
server = nil
begin
  puts "ubiblk: #{Spike::UBIBLK_DIR}"
  puts "== host A: fill and pause =="
  vol_a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vm, = bring_up(slot_a, vol_a, template_dir)
  psql(slot_a, "CREATE TABLE t (id serial primary key, v text)")
  psql(slot_a, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, #{(data_mb * 1024 * 1024) / 128}) g")
  psql(slot_a, "CHECKPOINT")
  count = psql(slot_a, "SELECT count(*) FROM t")
  sum = psql(slot_a, "SELECT sum(hashtextextended(v, 0)) FROM t")
  puts "  #{count} rows, #{psql(slot_a, "SELECT pg_size_pretty(pg_database_size('postgres'))")}"
  vm.agent.call("pg_stop", timeout: 60)
  vm.agent.call("detach")
  vm.agent.close
  vm.remove_device("data")
  vm.shutdown(timeout: 10)
  vm = nil
  vol_a.stop

  server = Spike::RemoteStripeServer.new(vol_a, port: PORT)
  server.start
  puts "  serving the detached volume on #{PORT}"

  puts "== host B: resume with autofetch off =="
  vol_b = Spike::Volume.new(vol_a.id, root: HOST_B_ROOT)
  vol_b.create(size_gib: 2, keys_from: vol_a,
    source: {"type" => "remote", "address" => "127.0.0.1:#{PORT}", "autofetch" => false,
             "psk_identity" => server.psk_identity, "psk_secret" => Base64.decode64(server.psk)})
  vm, up_ms = bring_up(slot_b, vol_b, template_dir)
  psql(slot_b, "SELECT 1")
  puts "  first query at #{up_ms.round(1)} ms; stripes #{stripes(vol_b).inspect}"
  report["first_query_ms"] = up_ms
  report["stripes_at_first_query"] = stripes(vol_b)

  puts "== now tell the running backend to catch up =="
  t = Spike.now
  resp = vol_b.rpc("start_autofetch")
  puts "  start_autofetch -> #{resp.inspect}"
  report["rpc_response"] = resp

  # The ember must keep serving while the catch-up runs -- unless the run is
  # about an ember nobody is using.
  idle = ENV["IDLE"] == "1"
  limit_ms = idle ? Integer(ENV.fetch("IDLE_TIMEOUT", "60")) * 1000 : 300_000
  queries = 0
  last = nil
  loop do
    unless idle
      psql(slot_b, "SELECT count(*) FROM t")
      queries += 1
    end
    last = stripes(vol_b)
    break if last && last["fetched"] >= last["source"]
    if Spike.ms(t) > limit_ms
      report["stalled_at"] = last
      raise "catch-up stalled at #{last.inspect}" unless idle
      puts "  catch-up STALLED at #{last.inspect} after #{limit_ms / 1000} s idle"
      break
    end
    sleep 0.25
  end
  catch_ms = Spike.ms(t)
  report["idle"] = idle
  unless report["stalled_at"]
    puts "  caught up in #{(catch_ms / 1000).round(2)} s (#{last.inspect}), " \
         "served #{queries} queries during catch-up"
    report["catch_up_ms"] = catch_ms
  end
  report["queries_during_catch_up"] = queries

  if report["stalled_at"]
    # Still depending on the source, so it cannot be taken away.
    report["verify_after_source_gone"] = nil
  else
    puts "== host A goes away =="
    server.stop
    server = nil
    got_count = psql(slot_b, "SELECT count(*) FROM t")
    got_sum = psql(slot_b, "SELECT sum(hashtextextended(v, 0)) FROM t")
    ok = got_count == count && got_sum == sum
    puts "  rows=#{got_count} checksum_match=#{got_sum == sum} => #{ok ? "PASS" : "FAIL"}"
    report["verify_after_source_gone"] = ok
  end
ensure
  begin
    vm&.shutdown(timeout: 5)
  rescue
    nil
  end
  server&.stop
  vol_a.stop
  vol_b&.stop
  File.write("/root/ember_spikes/out/s10_deferred_autofetch.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
end
