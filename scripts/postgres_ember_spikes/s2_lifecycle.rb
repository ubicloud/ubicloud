#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S1 (hot-plug, pg_start) + S2 (volume lifecycle, same-host re-attach).
#
# Cold create from the PGDATA raw stripe source, write data, pause, resume on
# the same host, verify the data survived, repeat.
#
#   ruby s2_lifecycle.rb [template] [cycles] [restore_mode]

require_relative "lib/ember"

template = ARGV[0] || "t512"
cycles = Integer(ARGV[1] || 3)
mode = ARGV[2] || "ondemand"
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = ENV["PGDATA_IMAGE"] || "#{Spike::IMAGES}/cell-pgdata-18.raw"

SLOT = 200
PASSWORD = "ember-#{SecureRandom.hex(8)}"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
slot = Spike::Slot.new(SLOT)
slot.create
vol = Spike::Volume.new("dv#{SecureRandom.hex(4)}")

def psql(slot, sql, password, timeout: 30)
  out = Spike.sh("ip", "netns", "exec", slot.netns,
    "env", "PGPASSWORD=#{password}", "PGCONNECT_TIMEOUT=#{timeout}",
    "psql", "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres",
    "-tAqX", "-c", sql)
  out.strip
end

# Bring an ember up on this slot against an existing volume.
def start_ember(slot, vol, template_dir, mode, password, first_start:)
  ph = {}
  t = Spike.now
  vol.start
  ph[:volume] = Spike.ms(t)

  vm = Spike::Vm.new(slot)
  t1 = Spike.now
  dir = vm.prepare_restore_dir(template_dir)
  vm.restore(dir, memory_restore_mode: mode)
  vm.wait_api_socket(timeout: 30)
  vm.wait_state("Running", timeout: 30)
  ph[:restore] = Spike.ms(t1)

  t2 = Spike.now
  vm.agent.wait_ready(timeout: 30)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round, ember_id: "ember-spike")
  ph[:post_restore] = Spike.ms(t2)

  t3 = Spike.now
  vm.add_disk(vhost_sock: vol.vhost_sock)
  ph[:hotplug] = Spike.ms(t3)

  t4 = Spike.now
  att = vm.agent.call("attach", device: "cldata", mount: "/data")
  ph[:attach] = Spike.ms(t4)
  ph[:attach_dev] = att["device_ms"]
  ph[:fsck_ran] = att["fsck_ran"]

  t5 = Spike.now
  st = vm.agent.call("pg_start", superuser_password: password, database: "postgres",
    settings: {"statement_timeout" => "60s"}, timeout: 60)
  ph[:pg_start] = Spike.ms(t5)
  ph[:pg_ctl] = st["pg_start_ms"]
  ph[:recovery_ran] = st["recovery_ran"]

  t6 = Spike.now
  psql(slot, "SELECT 1", password)
  ph[:first_query] = Spike.ms(t6)
  ph[:total] = Spike.ms(t)
  [vm, ph]
end

def pause_ember(vm, vol)
  ph = {}
  t = Spike.now
  r = vm.agent.call("pg_stop", timeout: 60)
  ph[:pg_stop] = Spike.ms(t)
  ph[:clean] = r["clean"]
  t1 = Spike.now
  vm.agent.call("detach")
  ph[:detach] = Spike.ms(t1)
  vm.agent.close
  t2 = Spike.now
  vm.remove_device("data")
  ph[:unplug] = Spike.ms(t2)
  t3 = Spike.now
  vm.shutdown(timeout: 10)
  ph[:vm_stop] = Spike.ms(t3)
  t4 = Spike.now
  vol.stop
  ph[:backend_stop] = Spike.ms(t4)
  ph[:total] = Spike.ms(t)
  ph
end

def fmt(ph)
  ph.map { |k, v| "#{k}=#{v.is_a?(Float) ? v.round(1) : v}" }.join(" ")
end

results = {"create" => nil, "pause" => [], "resume" => []}
begin
  puts "creating volume #{vol.id} from #{pgdata_image} (raw stripe source, copy_on_read)"
  vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})

  vm, ph = start_ember(slot, vol, template_dir, mode, PASSWORD, first_start: true)
  results["create"] = ph
  puts "CREATE  #{fmt(ph)}"

  puts "server: #{psql(slot, "SELECT version()", PASSWORD)[0, 60]}"
  psql(slot, "CREATE TABLE IF NOT EXISTS t (id serial primary key, v text)", PASSWORD)
  psql(slot, "INSERT INTO t (v) SELECT md5(g::text) FROM generate_series(1, 200000) g", PASSWORD)
  rows = psql(slot, "SELECT count(*) FROM t", PASSWORD)
  sum = psql(slot, "SELECT sum(hashtextextended(v, 0)) FROM t", PASSWORD)
  size = psql(slot, "SELECT pg_size_pretty(pg_database_size('postgres'))", PASSWORD)
  puts "wrote #{rows} rows, db #{size}, checksum #{sum}"

  # The gateway reaches an ember at the slot's public address, from outside the
  # slot namespace, through the DNAT rule in appendix E.
  pub = Spike.sh("env", "PGPASSWORD=#{PASSWORD}", "PGCONNECT_TIMEOUT=10", "psql",
    "-h", slot.public_ip6, "-U", "postgres", "-d", "postgres", "-tAqX",
    "-c", "SELECT 'reached via ' || inet_server_addr()", check: false).strip
  puts "GATEWAY PATH (host root netns -> #{slot.public_ip6}:5432): #{pub}"
  results["gateway_path"] = pub

  t = Spike.now
  vm.agent.call("configure", superuser_password: PASSWORD, database: "postgres")
  claim_ms = Spike.ms(t)
  results["claim"] = claim_ms
  puts "CLAIM (configure on an already-running ember) #{claim_ms.round(1)} ms"

  cycles.times do |i|
    p1 = pause_ember(vm, vol)
    results["pause"] << p1
    puts "PAUSE #{i}  #{fmt(p1)}"

    vm, p2 = start_ember(slot, vol, template_dir, mode, PASSWORD, first_start: false)
    results["resume"] << p2
    puts "RESUME #{i} #{fmt(p2)}"

    got_rows = psql(slot, "SELECT count(*) FROM t", PASSWORD)
    got_sum = psql(slot, "SELECT sum(hashtextextended(v, 0)) FROM t", PASSWORD)
    ok = got_rows == rows && got_sum == sum
    puts "VERIFY #{i} rows=#{got_rows} checksum_match=#{got_sum == sum} => #{ok ? "PASS" : "FAIL"}"
    raise "data mismatch after resume" unless ok
  end

  st = begin
    vol.rpc("status")
  rescue
    nil
  end
  puts "volume rpc status: #{st.inspect}"
  puts "volume on disk: #{Spike.sh("du", "-sh", vol.dir).strip}"
ensure
  begin
    vm&.shutdown(timeout: 5)
  rescue
    nil
  end
  vol.stop
  File.write("/root/ember_spikes/out/s2_lifecycle.json", JSON.pretty_generate(results))
  puts "(volume left at #{vol.dir}; slot #{slot.name} left up)"
end
