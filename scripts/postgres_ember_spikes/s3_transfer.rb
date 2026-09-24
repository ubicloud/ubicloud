#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S2, cross-host leg: resume a paused ember on a different host, sourcing the
# volume from the old host over the ubiblk remote stripe protocol (storage
# design approach 2 / design doc 6.1 `detached_local` -> other host).
#
# The second "host" is simulated by a second storage root and a second slot on
# this machine; the transfer still goes through remote-stripe-server over TCP.
#
#   ruby s3_transfer.rb [template] [mb_of_data]

require_relative "lib/ember"

template = ARGV[0] || "t512"
data_mb = Integer(ARGV[1] || 200)
autofetch = (ARGV[2] || "true") == "true"
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_B_ROOT = "/var/storage/detachable-hostb"
PASSWORD = "ember-#{SecureRandom.hex(8)}"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(HOST_B_ROOT)
slot_a = Spike::Slot.new(200).create
slot_b = Spike::Slot.new(201).create

def psql(slot, sql, timeout: 60)
  Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}",
    "PGCONNECT_TIMEOUT=#{timeout}", "psql", "-h", Spike::GUEST_IP6, "-U", "postgres",
    "-d", "postgres", "-tAqX", "-c", sql).strip
end

def bring_up(slot, vol, template_dir)
  ph = {}
  t = Spike.now
  vol.start
  ph[:volume] = Spike.ms(t)
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 30)
  vm.wait_state("Running", timeout: 30)
  vm.agent.wait_ready(timeout: 30)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  att = vm.agent.call("attach", device: "cldata", mount: "/data")
  ph[:fsck_ran] = att["fsck_ran"]
  st = vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 120)
  ph[:recovery_ran] = st["recovery_ran"]
  ph[:pg_ready] = Spike.ms(t)
  psql(slot, "SELECT 1")
  ph[:first_query] = Spike.ms(t)
  [vm, ph]
end

def pause(vm, vol)
  vm.agent.call("pg_stop", timeout: 60)
  vm.agent.call("detach")
  vm.agent.close
  vm.remove_device("data")
  vm.shutdown(timeout: 10)
  vol.stop
end

def stripes(vol)
  vol.rpc("status").dig("status", "stripes")
rescue
  nil
end

vol_a = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
vol_b = nil
server = nil
vm = nil
report = {}
begin
  puts "== host A: create and fill =="
  vol_a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vm, ph = bring_up(slot_a, vol_a, template_dir)
  puts "  up in #{ph[:first_query]} ms"
  psql(slot_a, "CREATE TABLE t (id serial primary key, v text)")
  rows = (data_mb * 1024 * 1024) / 128
  psql(slot_a, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, #{rows}) g")
  psql(slot_a, "CHECKPOINT")
  size = psql(slot_a, "SELECT pg_size_pretty(pg_database_size('postgres'))")
  count = psql(slot_a, "SELECT count(*) FROM t")
  sum = psql(slot_a, "SELECT sum(hashtextextended(v, 0)) FROM t")
  puts "  wrote #{count} rows, database #{size}"

  pause(vm, vol_a)
  vm = nil
  a_stripes = stripes(vol_a)
  puts "  paused; host A volume #{Spike.sh("du", "-sh", vol_a.dir).split.first}, stripes #{a_stripes.inspect}"
  report["host_a_stripes"] = a_stripes

  puts "== host A: serve the detached volume =="
  server = Spike::RemoteStripeServer.new(vol_a, port: 5501)
  t = Spike.now
  server.start
  puts "  remote-stripe-server listening on 5501 in #{Spike.ms(t)} ms"

  puts "== host B: resume from the remote source (autofetch=#{autofetch}) =="
  vol_b = Spike::Volume.new(vol_a.id, root: HOST_B_ROOT)
  t = Spike.now
  vol_b.create(size_gib: 2, keys_from: vol_a,
    source: {"type" => "remote", "address" => "127.0.0.1:5501", "autofetch" => autofetch,
             "psk_identity" => server.psk_identity, "psk_secret" => Base64.decode64(server.psk)})
  create_ms = Spike.ms(t)
  vm, ph = bring_up(slot_b, vol_b, template_dir)
  puts "  volume create #{create_ms.round(1)} ms, up in #{ph[:first_query]} ms " \
       "(fsck=#{ph[:fsck_ran]} recovery=#{ph[:recovery_ran]})"
  report["resume_remote"] = ph.merge("volume_create_ms" => create_ms)

  got_count = psql(slot_b, "SELECT count(*) FROM t")
  got_sum = psql(slot_b, "SELECT sum(hashtextextended(v, 0)) FROM t")
  ok = got_count == count && got_sum == sum
  puts "  VERIFY rows=#{got_count} checksum_match=#{got_sum == sum} => #{ok ? "PASS" : "FAIL"}"
  report["verify_remote"] = ok

  puts "== host B: background catch-up =="
  t = Spike.now
  last = nil
  loop do
    st = stripes(vol_b)
    last = st
    break if st && st["fetched"] >= st["source"]
    if Spike.ms(t) > 120_000
      puts "  NOT caught up after 120 s: #{st.inspect} (lazy copy-on-read only)"
      break
    end
    sleep 0.5
  end
  catch_ms = Spike.ms(t)
  puts "  caught up in #{(catch_ms / 1000).round(1)} s (#{last.inspect})"
  report["catch_up_ms"] = catch_ms
  report["host_b_stripes"] = last

  # With every stripe local, host B no longer needs host A at all.
  server.stop
  server = nil
  got_sum2 = psql(slot_b, "SELECT sum(hashtextextended(v, 0)) FROM t")
  puts "  after stopping host A's server, checksum_match=#{got_sum2 == sum}"
  report["verify_after_source_gone"] = (got_sum2 == sum)
ensure
  begin
    vm&.shutdown(timeout: 5)
  rescue
    nil
  end
  server&.stop
  vol_a.stop
  vol_b&.stop
  File.write("/root/ember_spikes/out/s3_transfer.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
end
