#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S5 from the design doc: density.
#
# Fill a host with running embers, then measure what it costs and whether a
# fresh restore is still fast at high occupancy. Pass condition in the design:
# p95 restore under 1 s at 90 percent slot occupancy.
#
#   ruby s6_density.rb [count] [template] [mode]

require_relative "lib/ember"

count = Integer(ARGV[0] || 100)
template = ARGV[1] || "t512"
mode = ARGV[2] || "ondemand"
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
PASSWORD = "ember-density"
SLOT_BASE = 1000

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
Spike.sh("rm", "-rf", *Dir["/var/storage/detachable/*"], check: false) if Dir.exist?("/var/storage/detachable")

def meminfo
  File.read("/proc/meminfo").scan(/^(\w+):\s+(\d+) kB/).to_h { |k, v| [k, v.to_i] }
end

# RSS by process family. /proc/<pid>/comm truncates to 15 characters, so match
# on the command line instead.
def rss_mib
  totals = Hash.new(0)
  Dir["/proc/[0-9]*"].each do |d|
    cmd = File.read("#{d}/cmdline")
    kind = if cmd.include?("cloud-hypervisor")
      :ch
    elsif cmd.include?("vhost-backend")
      :ubiblk
    end
    next unless kind
    totals[kind] += File.read("#{d}/statm").split[1].to_i * 4096
  rescue SystemCallError
    next
  end
  totals.transform_values { (_1 / 1048576.0).round(1) }
end

def loadavg = File.read("/proc/loadavg").split[0, 3].join(" ")

def bring_up(i, template_dir, pgdata_image, mode, with_pg:)
  slot = Spike::Slot.new(SLOT_BASE + i)
  slot.create
  vol = Spike::Volume.new(format("dvden%04d", i))
  FileUtils.rm_rf(vol.dir)
  t = Spike.now
  vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vol.start
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: mode)
  vm.wait_api_socket(timeout: 60)
  vm.wait_state("Running", timeout: 60)
  vm.agent.wait_ready(timeout: 60)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round, ember_id: "ember-den-#{i}")
  vm.add_disk(vhost_sock: vol.vhost_sock)
  vm.agent.call("attach", device: "cldata", mount: "/data", timeout_s: 30)
  if with_pg
    vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 180)
  end
  [vm, vol, slot, Spike.ms(t)]
end

vms = []
vols = []
latencies = []
base_mem = meminfo
report = {"count" => count, "mode" => mode}

begin
  puts "== ramping to #{count} running embers (#{mode}, PostgreSQL started in each) =="
  count.times do |i|
    vm, vol, _slot, ms = bring_up(i, template_dir, pgdata_image, mode, with_pg: true)
    vms << vm
    vols << vol
    latencies << ms
    if ((i + 1) % 10).zero? || i == count - 1
      m = meminfo
      used = ((base_mem["MemAvailable"] - m["MemAvailable"]) / 1024.0).round
      r = rss_mib
      puts format("  %3d up  last=%7.1f ms  p50=%7.1f  p95=%7.1f  ch_rss=%8.1f  ubiblk_rss=%7.1f  " \
                  "host_used=%6d MiB (%5.1f MiB/ember)  load=%s",
        i + 1, ms, Spike.percentile(latencies.sort, 50), Spike.percentile(latencies.sort, 95),
        r[:ch].to_f, r[:ubiblk].to_f, used, used.to_f / (i + 1), loadavg)
    end
  rescue => e
    warn "  ember #{i} failed: #{e.message}"
    report["ramp_failed_at"] = i
    break
  end

  sorted = latencies.sort
  report["ramp"] = {"n" => latencies.length, "p50" => Spike.percentile(sorted, 50),
                    "p95" => Spike.percentile(sorted, 95), "max" => sorted.last}
  m = meminfo
  report["rss_mib"] = rss_mib
  report["host_used_mib"] = ((base_mem["MemAvailable"] - m["MemAvailable"]) / 1024.0).round
  report["per_ember_mib"] = (report["host_used_mib"].to_f / [vms.length, 1].max).round(1)
  report["loadavg"] = loadavg

  puts "== with #{vms.length} embers running, how fast is one more? =="
  extra = []
  3.times do |k|
    vm, vol, _slot, ms = bring_up(count + k, template_dir, pgdata_image, mode, with_pg: true)
    vms << vm
    vols << vol
    extra << ms
    puts format("  extra ember %d: %.1f ms", k, ms)
  end
  report["at_occupancy"] = extra

  puts "== query latency on one ember with #{vms.length} neighbours =="
  slot = vms.first.slot
  t = Spike.now
  n = 200
  n.times {
    Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}",
      "psql", "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX", "-c", "SELECT 1")
  }
  per = Spike.ms(t) / n
  puts format("  %d connect+SELECT round trips, %.1f ms each", n, per)
  report["connect_query_ms"] = per.round(2)

  st = File.read("/proc/meminfo")[/MemAvailable:\s+(\d+)/, 1].to_i / 1024
  puts "== summary =="
  puts "  #{vms.length} embers running, #{report["host_used_mib"]} MiB of host memory " \
       "(#{report["per_ember_mib"]} MiB each), #{st} MiB still available"
  puts "  disk: #{Spike.sh("du", "-sh", "/var/storage/detachable").split.first} across #{vols.length} volumes"
  report["disk"] = Spike.sh("du", "-sh", "/var/storage/detachable").split.first
ensure
  puts "== tearing down =="
  vms.each do |vm|
    vm.kill
  rescue
    nil
  end
  vols.each do |v|
    v.stop
  rescue
    nil
  end
  Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
  File.write("/root/ember_spikes/out/s6_density.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
end
