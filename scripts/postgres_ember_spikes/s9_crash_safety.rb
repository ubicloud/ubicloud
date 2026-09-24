#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Does an ember survive an unclean pause?
#
# Section 4.1 of the design builds the PGDATA image with `mkfs.ext4
# -O ^has_journal`. An ember is killed abruptly by definition (host loss, OOM,
# a pause that times out), so this compares the journalled and non-journalled
# images under two failure modes:
#
#   vm_kill     cloud-hypervisor is killed, the ubiblk backend keeps running
#               and flushes what it already has
#   host_crash  both the VM and the backend are killed, losing the backend's
#               unflushed writes as a host crash would
#
#   ruby s9_crash_safety.rb [template] [rounds]

require_relative "lib/ember"

template = ARGV[0] || "t512"
rounds = Integer(ARGV[1] || 3)
template_dir = File.join(Spike::TEMPLATES, template)
PASSWORD = "ember-crash"
SLOT_N = 600
FAILURE_MODES = %w[vm_kill host_crash].freeze

# When the VM is killed mid-query the peer vanishes without an RST, so psql
# blocks on the read forever; everything here runs under a hard timeout.
def psql(slot, sql, check: true, timeout_s: 120)
  Spike.sh("timeout", "-s", "KILL", timeout_s.to_s,
    "ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}",
    "PGCONNECT_TIMEOUT=30", "psql", "-h", Spike::GUEST_IP6, "-U", "postgres",
    "-d", "postgres", "-tAqX", "-c", sql, check:).strip
end

# The caller owns the Vm object so that diagnostics can still be collected
# from the guest when bring-up fails.
def bring_up(slot, vol, template_dir, clean:, vm: nil)
  vol.start
  vm ||= Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 60)
  vm.wait_state("Running", timeout: 60)
  vm.agent.wait_ready(timeout: 60)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  att = vm.agent.call("attach", device: "cldata", mount: "/data",
    clean_shutdown: clean, timeout_s: 60)
  st = vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 180)
  [vm, att, st]
end

# What does the guest itself say about the filesystem and the postmaster?
def guest_diagnostics(vm)
  return "(no vm)" unless vm
  vm.agent.call("exec", timeout_s: 120, argv: ["sh", "-c",
    "echo '--- pg.log ---'; tail -20 /run/ember/pg.log 2>&1; " \
    "echo '--- dmesg ---'; dmesg | tail -15; " \
    "echo '--- mount ---'; mount | grep /data; " \
    "echo '--- pgdata ---'; ls -la /data/pgdata 2>&1 | head -8; " \
    "echo '--- manual start ---'; su -s /bin/sh postgres -c " \
    "'/usr/lib/postgresql/18/bin/postgres -D /data/pgdata 2>&1 | head -20' &" \
    "sleep 3; kill %1 2>/dev/null"])["stdout"]
rescue => e
  "(diagnostics failed: #{e.message.lines.first})"
end

report = {}
%w[journal nojournal].each do |variant|
  image = (variant == "journal") ?
    "#{Spike::IMAGES}/cell-pgdata-18.raw" :
    "#{Spike::IMAGES}/cell-pgdata-18-nojournal.raw"
  unless File.exist?(image)
    puts "== #{variant}: #{image} missing, skipping =="
    next
  end

  FAILURE_MODES.each do |mode|
    label = "#{variant}/#{mode}"
    puts "== #{label} =="
    Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
    slot = Spike::Slot.new(SLOT_N).create
    vol = Spike::Volume.new("dvcrash")
    FileUtils.rm_rf(vol.dir)
    vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => image, "copy_on_read" => true})
    outcome = []
    vm = nil
    begin
      vm, = bring_up(slot, vol, template_dir, clean: true)
      psql(slot, "CREATE TABLE t (id serial primary key, v text)")
      psql(slot, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, 300000) g")
      psql(slot, "CHECKPOINT")
      committed = psql(slot, "SELECT count(*) FROM t")
      psql(slot, "SELECT sum(hashtextextended(v, 0)) FROM t")

      rounds.times do |i|
        # Keep writing right up to the moment of the kill.
        writer = Thread.new do
          psql(slot, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, 200000) g",
            check: false, timeout_s: 15)
        end
        sleep 0.4
        vm.kill
        vol.stop_hard if mode == "host_crash"
        writer.join
        vol.stop

        begin
          vm = Spike::Vm.new(slot)
          vm, att, st = bring_up(slot, vol, template_dir, clean: false, vm:)
          got = psql(slot, "SELECT count(*) FROM t")
          gotsum = psql(slot, "SELECT sum(hashtextextended(v, 0)) FROM t")
          # Rows committed before the kill must all still be there, and every
          # row that is there must be intact.
          ok = got.to_i >= committed.to_i && !gotsum.empty?
          full = psql(slot, "SELECT count(*) FROM t WHERE v IS NOT NULL", check: false)
          outcome << {"round" => i, "ok" => ok, "rows" => got.to_i,
                      "committed_before" => committed.to_i, "fsck_ran" => att["fsck_ran"],
                      "fsck_rc" => att["fsck_rc"], "recovery" => st["recovery_ran"],
                      "full_scan" => full}
          puts format("  round %d: rows=%-8s (>=%s) fsck_rc=%-4s recovery=%-5s full_scan=%-8s => %s",
            i, got, committed, att["fsck_rc"].inspect, st["recovery_ran"], full, ok ? "ok" : "DATA LOSS")
          committed = got
        rescue => e
          diag = guest_diagnostics(vm)
          outcome << {"round" => i, "ok" => false, "error" => e.message.lines.first.to_s.strip,
                      "diagnostics" => diag}
          puts "  round #{i}: FAILED TO COME BACK: #{e.message.lines.first.to_s.strip[0, 160]}"
          puts diag.to_s.lines.last(14).map { "      #{_1}" }.join
          break
        end
      end
    rescue => e
      puts "  setup failed: #{e.message.lines.first}"
      outcome << {"setup_error" => e.message.lines.first.to_s.strip}
    ensure
      begin
        vm&.kill
      rescue
        nil
      end
      vol.stop
    end
    report[label] = outcome
  end
end

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
File.write("/root/ember_spikes/out/s9_crash_safety.json", JSON.pretty_generate(report))
puts JSON.pretty_generate(report)
