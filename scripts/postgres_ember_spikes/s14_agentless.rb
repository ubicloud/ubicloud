#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S14: the agentless guest, the production image as built by
# postgres-vm-images' ember/build.sh. Same lifecycle as s2_lifecycle.rb,
# but nothing in the guest listens for the host: the data disk's hot-plug
# drives the restore hook (CRNG reseed + clock from ptp_kvm), fsck, the /data
# mount and PostgreSQL through udev and systemd, the host configures
# PostgreSQL over SQL from the slot's tap address, and pause is the ACPI
# power button.
#
#   ruby build_template_agentless.rb a512 /var/storage/ember/images/cell-root-18.raw
#   ruby s14_agentless.rb lifecycle [template] [cycles]
#   ruby s14_agentless.rb clones    [template]

require_relative "lib/ember"

MODE = ARGV[0] || "lifecycle"
TEMPLATE = ARGV[1] || "a512"
CYCLES = Integer(ARGV[2] || 5)
PGDATA_IMAGE = "#{Spike::IMAGES}/cell-pgdata-18.raw"
PASSWORD = "ember-#{SecureRandom.hex(8)}"

def psql(slot, sql, password: nil, timeout: 30)
  env = password ? ["PGPASSWORD=#{password}"] : []
  Spike.sh("ip", "netns", "exec", slot.netns, "env", *env, "PGCONNECT_TIMEOUT=#{timeout}",
    "psql", "-h", Spike::GUEST_IP6, "-U", "postgres", "-d", "postgres", "-tAqX",
    *Array(sql).flat_map { |q| ["-c", q] }).strip
end

# PQping from the host's root namespace, through the slot's public address:
# an authentication request means the postmaster is accepting connections.
def pg_ping(host)
  s = Socket.tcp(host, 5432, connect_timeout: 0.2)
  body = "user\0postgres\0database\0postgres\0\0"
  s.write([8 + body.bytesize, 196608].pack("NN") + body)
  return false unless IO.select([s], nil, nil, 1)
  tag = s.read(1)
  return true if tag == "R"
  tag == "E" && !s.read_nonblock(4096, exception: false).to_s.include?("57P03")
rescue SystemCallError, IOError
  false
ensure
  s&.close
end

def wait_ready(slot, timeout: 60)
  deadline = Spike.now + timeout
  polls = 0
  until pg_ping(slot.public_ip6)
    polls += 1
    raise "postgres never came up" if Spike.now > deadline
    sleep 0.010
  end
  polls
end

def start_ember(slot, vol, template_dir)
  ph = {}
  t = Spike.now
  vol.start
  ph[:volume] = Spike.ms(t)

  vm = Spike::Vm.new(slot)
  t1 = Spike.now
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 30)
  vm.wait_state("Running", timeout: 30)
  ph[:restore] = Spike.ms(t1)

  t2 = Spike.now
  vm.add_disk(vhost_sock: vol.vhost_sock)
  ph[:hotplug] = Spike.ms(t2)
  hotplugged_at = Time.now.to_f

  t3 = Spike.now
  ph[:polls] = wait_ready(slot)
  ph[:until_ready] = Spike.ms(t3)

  # The management role is trusted from the tap address only, which nothing
  # but a process in the slot's namespace on the host can originate from.
  t4 = Spike.now
  psql(slot, ["ALTER ROLE postgres PASSWORD '#{PASSWORD}'", "ALTER SYSTEM SET statement_timeout = '60s'", "SELECT pg_reload_conf()"])
  ph[:configure] = Spike.ms(t4)

  t5 = Spike.now
  psql(slot, "SELECT 1", password: PASSWORD)
  ph[:first_query] = Spike.ms(t5)
  ph[:total] = Spike.ms(t)
  # The guest's clock has been set from the host by then, so the postmaster's
  # start time can be placed on the host's timeline.
  pm = psql(slot, "SELECT extract(epoch from pg_postmaster_start_time())", password: PASSWORD).to_f
  ph[:postmaster_after_hotplug] = ((pm - hotplugged_at) * 1000).round(1)
  [vm, ph]
end

def pause_ember(vm, vol)
  ph = {}
  t = Spike.now
  vm.ch_remote("power-button")
  deadline = Spike.now + 60
  sleep 0.005 while vm.alive? && Spike.now < deadline
  ph[:powered_off] = !vm.alive?
  ph[:power_button_to_exit] = Spike.ms(t)
  vm.kill
  t1 = Spike.now
  vol.stop
  ph[:backend_stop] = Spike.ms(t1)
  ph[:total] = Spike.ms(t)
  ph
end

# Offset of the guest's wall clock from the host's, bounded by the round trip.
def clock_offset_ms(slot)
  before = Time.now.to_f
  guest = psql(slot, "SELECT extract(epoch from clock_timestamp())", password: PASSWORD).to_f
  after = Time.now.to_f
  [((guest - (before + after) / 2) * 1000).round(1), ((after - before) * 1000 / 2).round(1)]
end

def fmt(ph) = ph.map { |k, v| "#{k}=#{v.is_a?(Float) ? v.round(1) : v}" }.join(" ")

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
template_dir = File.join(Spike::TEMPLATES, TEMPLATE)
results = {"template" => TEMPLATE}

case MODE
when "lifecycle"
  slot = Spike::Slot.new(201)
  slot.create
  vol = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
  vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => PGDATA_IMAGE, "copy_on_read" => true})
  begin
    vm, ph = start_ember(slot, vol, template_dir)
    results["create"] = ph
    puts "CREATE   #{fmt(ph)}"
    off, rtt = clock_offset_ms(slot)
    puts "CLOCK    guest-host offset #{off} ms (+/- #{rtt} ms)"
    psql(slot, "CREATE TABLE t (id serial primary key, v text); INSERT INTO t (v) SELECT md5(g::text) FROM generate_series(1, 200000) g", password: PASSWORD)
    sum = psql(slot, "SELECT count(*) || ':' || sum(hashtextextended(v, 0)) FROM t", password: PASSWORD)
    results["pause"] = []
    results["resume"] = []
    CYCLES.times do |i|
      p1 = pause_ember(vm, vol)
      results["pause"] << p1
      puts "PAUSE  #{i} #{fmt(p1)}"
      vm, p2 = start_ember(slot, vol, template_dir)
      p2[:clock_offset_ms], = clock_offset_ms(slot)
      results["resume"] << p2
      puts "RESUME #{i} #{fmt(p2)}"
      got = psql(slot, "SELECT count(*) || ':' || sum(hashtextextended(v, 0)) FROM t", password: PASSWORD)
      raise "data mismatch after resume" unless got == sum
    end
    puts "VERIFY   data intact across #{CYCLES} pause/resume cycles"
  ensure
    vm&.kill
    vol.stop
  end
when "clones"
  # Two clones of one template, restored side by side, each with its own
  # volume. Without a reseed they start from the same CRNG state.
  embers = [202, 203].map do |n|
    slot = Spike::Slot.new(n)
    slot.create
    vol = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
    vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => PGDATA_IMAGE, "copy_on_read" => true})
    [slot, vol]
  end
  vms = []
  begin
    embers.each do |slot, vol|
      vm, ph = start_ember(slot, vol, template_dir)
      vms << vm
      puts "CLONE #{slot.name} #{fmt(ph)}"
    end
    samples = embers.map do |slot, _|
      {
        "kernel_uuid" => psql(slot, "SELECT pg_read_file('/proc/sys/kernel/random/uuid')", password: PASSWORD).strip,
        "gen_random_uuid" => psql(slot, "SELECT gen_random_uuid()", password: PASSWORD),
        "boot_id" => psql(slot, "SELECT pg_read_file('/proc/sys/kernel/random/boot_id')", password: PASSWORD).strip,
      }
    end
    samples.each_with_index { |s, i| puts "CLONE #{i} #{s.inspect}" }
    %w[kernel_uuid gen_random_uuid boot_id].each do |k|
      puts "#{k.ljust(16)} #{(samples[0][k] == samples[1][k]) ? "IDENTICAL" : "differ"}"
    end
    results["samples"] = samples
  ensure
    vms.each(&:kill)
    embers.each { |_, vol| vol.stop }
  end
end
File.write(File.join(__dir__, "out", "s14_#{MODE}_#{TEMPLATE}.json"), JSON.pretty_generate(results))
