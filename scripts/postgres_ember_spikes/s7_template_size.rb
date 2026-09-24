#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Design doc section 14, decision 1: is 384 MiB (or less) a viable template
# size for the <= 1 GB data target, and what does it buy?
#
#   ruby s7_template_size.rb 512 384 256

require_relative "lib/ember"

sizes = (ARGV.empty? ? %w[512 384 256] : ARGV).map { Integer(_1) }
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
PASSWORD = "ember-size"
report = {}

sizes.each do |mib|
  name = "t#{mib}"
  puts "== #{mib} MiB template =="
  Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
  build = Spike.sh("ruby", File.join(__dir__, "build_template.rb"), name, mib.to_s, check: false)
  unless File.exist?(File.join(Spike::TEMPLATES, name, "config.json"))
    puts "  template build FAILED (guest did not come up at #{mib} MiB)"
    puts build.lines.last(3).map { "    #{_1}" }.join
    report[mib] = {"built" => false}
    next
  end
  puts "  #{build[/guest quiet[^\n]*/]}"

  slot = Spike::Slot.new(400).create
  vol = Spike::Volume.new("dvsize#{mib}")
  FileUtils.rm_rf(vol.dir)
  vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})

  restores = []
  creates = []
  vm = nil
  5.times do |i|
    vm&.kill
    vol.stop
    t = Spike.now
    vol.start
    vm = Spike::Vm.new(slot)
    vm.restore(vm.prepare_restore_dir(File.join(Spike::TEMPLATES, name)), memory_restore_mode: "ondemand")
    vm.wait_api_socket(timeout: 60)
    vm.wait_state("Running", timeout: 60)
    vm.agent.wait_ready(timeout: 60)
    vm.agent.call("hello")
    restores << Spike.ms(t)
    vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32), unix_time_ms: (Time.now.to_f * 1000).round)
    vm.add_disk(vhost_sock: vol.vhost_sock)
    vm.agent.call("attach", device: "cldata", mount: "/data", timeout_s: 30)
    vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 120)
    creates << Spike.ms(t)
    if i.zero?
      # Does an ember this size survive real work?
      Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}", "psql",
        "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX", "-c",
        "CREATE TABLE IF NOT EXISTS t (id serial primary key, v text)")
      Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}", "psql",
        "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX", "-c",
        "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, 2000000) g")
      size = Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}", "psql",
        "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX", "-c",
        "SELECT pg_size_pretty(pg_database_size('postgres'))").strip
      idx = Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}", "psql",
        "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX", "-c",
        "CREATE INDEX ON t (v); SELECT count(*) FROM t", check: false).strip
      puts "  workload: database #{size}, index build + count => #{idx.empty? ? "FAILED" : idx}"
      report["workload_#{mib}"] = {"db_size" => size, "count" => idx}
    end
  end
  rss = begin
    pid = vm.pid
    (File.read("/proc/#{pid}/statm").split[1].to_i * 4096 / 1048576.0).round(1)
  rescue
    nil
  end
  mem = File.size(File.join(Spike::TEMPLATES, name, "memory-ranges"))
  puts "  " + Spike.summarize("restore->hello", restores)
  puts "  " + Spike.summarize("restore->pg ready", creates)
  puts "  cloud-hypervisor RSS after a full create: #{rss} MiB, memory-ranges #{(mem / 1048576.0).round} MiB"
  report[mib] = {"built" => true, "restore" => restores, "create" => creates,
                 "ch_rss_mib" => rss, "memory_ranges_mib" => (mem / 1048576.0).round}
  vm&.kill
  vol.stop
end

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
File.write("/root/ember_spikes/out/s7_template_size.json", JSON.pretty_generate(report))
