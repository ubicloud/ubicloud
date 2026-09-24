#!/usr/bin/env ruby
# frozen_string_literal: true

#
# What does deferring catch-up buy, and what does it cost the tenant?
#
# Resumes a volume from a remote source on a "new host" (a second storage root
# and slot) many times against one remote-stripe-server, in three arms:
#
#   A  autofetch from the start (stock behaviour)
#   B  autofetch off, start_autofetch RPC the moment SELECT 1 returns
#   C  autofetch off, never caught up (the floor)
#
# and runs a one-client pgbench against the ember straight after SELECT 1, so
# the tenant's latency during catch-up is measured, not only the first query.
#
#   UBIBLK_DIR=/opt/vhost-block-backend/<build> \
#     ruby s14_autofetch_impact.rb [template] [runs_per_arm] [mb_of_data] [pgbench_seconds]
#
# SHAPE_MBIT=1000 puts remote-stripe-server behind a veth pair in its own
# namespace, shaped to that rate; ARMS=AB restricts the arms.

require_relative "lib/ember"
require "time"

abort "export UBIBLK_DIR explicitly; the default is whichever build sorts last" unless ENV["UBIBLK_DIR"]

template = ARGV[0] || "t512"
RUNS = Integer(ARGV[1] || 7)
data_mb = Integer(ARGV[2] || 200)
BENCH_S = Integer(ARGV[3] || 8)
ARMS = (ENV["ARMS"] || "ABC").chars
SHAPE_MBIT = ENV["SHAPE_MBIT"]&.then { Integer(_1) }
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_B_ROOT = "/var/storage/detachable-hostb"
OUT = File.join(__dir__, "out")
PASSWORD = "ember-#{SecureRandom.hex(8)}"
PORT = 5505
PGBENCH = "/usr/lib/postgresql/18/bin/pgbench"
POLL_S = 0.05
TAG = SHAPE_MBIT ? "shaped#{SHAPE_MBIT}_" : ""

# The shaped pass: the server in its own namespace, reached over a veth pair
# with both ends limited to SHAPE_MBIT.
SRV_NS = "clsrv"
SRV_HOST_IF = "vsrvh"
SRV_NS_IF = "vsrvn"
SRV_HOST_ADDR = "10.254.0.1"
SRV_NS_ADDR = "10.254.0.2"

def shaped_setup
  Spike.sh("ip", "netns", "del", SRV_NS, check: false)
  Spike.sh("ip", "link", "del", SRV_HOST_IF, check: false)
  Spike.sh("ip", "netns", "add", SRV_NS)
  Spike.sh("ip", "link", "add", SRV_HOST_IF, "type", "veth", "peer", "name", SRV_NS_IF)
  Spike.sh("ip", "link", "set", SRV_NS_IF, "netns", SRV_NS)
  Spike.sh("ip", "addr", "add", "#{SRV_HOST_ADDR}/30", "dev", SRV_HOST_IF)
  Spike.sh("ip", "link", "set", SRV_HOST_IF, "up")
  Spike.sh("ip", "netns", "exec", SRV_NS, "ip", "addr", "add", "#{SRV_NS_ADDR}/30", "dev", SRV_NS_IF)
  Spike.sh("ip", "netns", "exec", SRV_NS, "ip", "link", "set", SRV_NS_IF, "up")
  Spike.sh("ip", "netns", "exec", SRV_NS, "ip", "link", "set", "lo", "up")
  rate = "#{SHAPE_MBIT}mbit"
  [["tc", "qdisc", "add", "dev", SRV_HOST_IF, "root", "tbf", "rate", rate, "burst", "256kb", "latency", "50ms"],
    ["ip", "netns", "exec", SRV_NS, "tc", "qdisc", "add", "dev", SRV_NS_IF, "root", "tbf", "rate", rate,
      "burst", "256kb", "latency", "50ms"]].each { Spike.sh(*_1) }
end

def shaped_teardown
  Spike.sh("ip", "netns", "del", SRV_NS, check: false)
  Spike.sh("ip", "link", "del", SRV_HOST_IF, check: false)
end

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), "--volumes", check: false)
FileUtils.rm_rf(HOST_B_ROOT)
FileUtils.mkdir_p([HOST_B_ROOT, OUT])
shaped_setup if SHAPE_MBIT
slot_a = Spike::Slot.new(200).create
slot_b = Spike::Slot.new(201).create
# The last B run stays up for the final data check, so the final C run needs
# a slot of its own.
slot_spare = Spike::Slot.new(202).create

def psql(slot, sql, timeout: 120)
  Spike.sh("timeout", "-s", "KILL", timeout.to_s, "ip", "netns", "exec", slot.netns,
    "env", "PGPASSWORD=#{PASSWORD}", "PGCONNECT_TIMEOUT=30", "psql", "-h", Spike::GUEST_IP6,
    "-U", "postgres", "-d", "postgres", "-tAqX", "-c", sql).strip
end

def stripes(vol)
  vol.rpc("status").dig("status", "stripes")
rescue
  nil
end

def restore_and_start(slot, vol, template_dir)
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 60)
  vm.wait_state("Running", timeout: 60)
  vm.agent.wait_ready(timeout: 60)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32), unix_time_ms: (Time.now.to_f * 1000).round)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  vm.agent.call("attach", device: "cldata", mount: "/data", timeout_s: 60)
  vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 180)
  vm
end

# Poll the status RPC every 50 ms from t0 until every stripe is local, or
# until told to stop. The first poll that sees it is the catch-up time.
class CatchUpPoller
  attr_reader :caught_up_ms, :caught_up_epoch, :last

  def initialize(vol, t0)
    @vol = vol
    @t0 = t0
    @stop = false
    @thread = Thread.new { run }
  end

  def run
    until @stop
      st = stripes(@vol)
      @last = st if st
      if st && st["fetched"] >= st["source"]
        @caught_up_ms = Spike.ms(@t0)
        @caught_up_epoch = Time.now.to_f
        return
      end
      sleep POLL_S
    end
  end

  def wait(timeout)
    @thread.join(timeout)
    stop
  end

  def stop
    @stop = true
    @thread.join
  end
end

report = {"ubiblk_dir" => Spike::UBIBLK_DIR, "uname_r" => `uname -r`.strip,
          "shape_mbit" => SHAPE_MBIT, "pgbench_seconds" => BENCH_S, "runs" => []}
vm_a = nil
vol_a = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
server = nil
kept = nil
begin
  puts "ubiblk: #{Spike::UBIBLK_DIR}#{" (server shaped to #{SHAPE_MBIT} Mbit/s)" if SHAPE_MBIT}"
  puts "== setup: fill host A, pause, serve =="
  vol_a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vol_a.start
  vm_a = restore_and_start(slot_a, vol_a, template_dir)
  psql(slot_a, "CREATE TABLE t (id serial primary key, v text)")
  psql(slot_a, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, #{(data_mb * 1024 * 1024) / 128}) g")
  psql(slot_a, "CHECKPOINT")
  count = psql(slot_a, "SELECT count(*) FROM t")
  sum = psql(slot_a, "SELECT sum(hashtextextended(v, 0)) FROM t")
  report["setup"] = {"rows" => Integer(count), "checksum" => sum,
                     "database_size" => psql(slot_a, "SELECT pg_size_pretty(pg_database_size('postgres'))")}
  puts "  #{count} rows, #{report["setup"]["database_size"]}"
  vm_a.agent.call("pg_stop", timeout: 60)
  vm_a.agent.call("detach")
  vm_a.agent.close
  vm_a.remove_device("data")
  vm_a.shutdown(timeout: 10)
  vm_a = nil
  vol_a.stop

  server = Spike::RemoteStripeServer.new(vol_a, port: PORT, netns: SHAPE_MBIT && SRV_NS,
    check_address: SHAPE_MBIT ? SRV_NS_ADDR : "127.0.0.1")
  server.start
  address = "#{SHAPE_MBIT ? SRV_NS_ADDR : "127.0.0.1"}:#{PORT}"
  puts "  serving the detached volume at #{address}"

  workload = File.join(OUT, "s14_workload.sql")
  File.write(workload, "\\set id random(1, #{count})\nSELECT v FROM t WHERE id = :id;\nUPDATE t SET v = v WHERE id = :id;\n")

  schedule = (1..RUNS).flat_map { |run| ARMS.map { |arm| [arm, run] } }
  schedule.each_with_index do |(arm, run), i|
    last_b = arm == "B" && run == RUNS
    slot = (arm == "C" && kept) ? slot_spare : slot_b
    root = File.join(HOST_B_ROOT, "#{arm}#{run}")
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)
    rec = {"arm" => arm, "run" => run, "started_at" => Time.now.utc.iso8601(3), "slot" => slot.netns}
    vol_b = Spike::Volume.new(vol_a.id, root:)
    vol_b.create(size_gib: 2, keys_from: vol_a,
      source: {"type" => "remote", "address" => address, "autofetch" => arm == "A",
               "psk_identity" => server.psk_identity, "psk_secret" => Base64.decode64(server.psk)})
    vm = nil
    poller = nil
    begin
      t0 = Spike.now
      vol_b.start(timeout: 120)
      poller = CatchUpPoller.new(vol_b, t0)
      report["version_rpc"] ||= vol_b.rpc("version")
      vm = restore_and_start(slot, vol_b, template_dir)
      rec["pg_ready_ms"] = Spike.ms(t0)
      psql(slot, "SELECT 1")
      rec["first_query_ms"] = Spike.ms(t0)
      if arm == "B"
        rec["rpc_at_ms"] = Spike.ms(t0)
        rec["rpc_response"] = vol_b.rpc("start_autofetch")
      end
      rec["stripes_at_first_query"] = stripes(vol_b)

      prefix = File.join(OUT, "s14_#{TAG}#{arm}_#{run}")
      Dir.glob("#{prefix}.*").each { File.delete(_1) }
      rec["pgbench_started_epoch"] = Time.now.to_f
      bench = Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}", PGBENCH,
        "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-n", "-c", "1", "-j", "1",
        "-T", BENCH_S.to_s, "-f", workload, "-l", "--log-prefix=#{prefix}")
      rec["pgbench_summary"] = bench.lines.grep(/latency average|number of transactions actually|tps/).map(&:strip)
      rec["pgbench_log"] = Dir.glob("#{prefix}.*").first

      if arm == "C"
        poller.stop
      else
        poller.wait(SHAPE_MBIT ? 600 : 180)
      end
      rec["caught_up_ms"] = poller.caught_up_ms
      rec["caught_up_epoch"] = poller.caught_up_epoch
      rec["independent_ms"] = poller.caught_up_ms
      rec["stripes_at_end"] = poller.last

      if last_b
        kept = [vm, vol_b]
        vm = nil
      end
    ensure
      poller&.stop
      if vm
        vm.shutdown(timeout: 5)
        vol_b.stop
        FileUtils.rm_rf(root)
      end
    end
    report["runs"] << rec
    puts format("%2d/%d %s%-2d first_query=%7.1f caught_up=%8s stripes@fq=%s",
      i + 1, schedule.size, arm, run, rec["first_query_ms"], rec["caught_up_ms"]&.round(1).inspect,
      rec["stripes_at_first_query"].inspect)
    File.write(File.join(OUT, "s14_#{TAG}autofetch_impact.json"), JSON.pretty_generate(report))
  end

  if kept
    puts "== verify on the last B run, with the source gone =="
    server.stop
    server = nil
    got_count = psql(slot_b, "SELECT count(*) FROM t")
    got_sum = psql(slot_b, "SELECT sum(hashtextextended(v, 0)) FROM t")
    ok = got_count == count && got_sum == sum
    report["verify_after_source_gone"] = {"rows" => got_count, "checksum_match" => got_sum == sum, "pass" => ok}
    puts "  rows=#{got_count} checksum_match=#{got_sum == sum} => #{ok ? "PASS" : "FAIL"}"
  end
ensure
  begin
    vm_a&.shutdown(timeout: 5)
    kept&.first&.shutdown(timeout: 5)
  rescue
    nil
  end
  kept&.last&.stop
  server&.stop
  vol_a.stop
  shaped_teardown if SHAPE_MBIT
  File.write(File.join(OUT, "s14_#{TAG}autofetch_impact.json"), JSON.pretty_generate(report))
end
