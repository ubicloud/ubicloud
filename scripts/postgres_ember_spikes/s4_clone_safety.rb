#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S3 from the design doc: clone safety.
#
# Restored clones share the snapshot's RNG state, clock and identity. Check
# that the post_restore step actually fixes that, that it is actually needed,
# and that the shared guest MAC/IP does not leak between slots.
#
#   ruby s4_clone_safety.rb [template] [clones]

require_relative "lib/ember"

template = ARGV[0] || "t512"
n = Integer(ARGV[1] || 3)
template_dir = File.join(Spike::TEMPLATES, template)

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
SLOT_BASE = 300
results = {}

def sample_random(vm, count = 4)
  out = vm.agent.call("exec", argv: ["sh", "-c",
    "for i in $(seq #{count}); do cat /proc/sys/kernel/random/uuid; done; " \
    "head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \\n'"], timeout_s: 30)["stdout"]
  out.strip.split("\n")
end

def boot_clones(n, template_dir, reseed:)
  vms = []
  n.times do |i|
    slot = Spike::Slot.new(SLOT_BASE + i)
    slot.create unless slot.exists?
    vm = Spike::Vm.new(slot)
    vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
    vm.wait_api_socket(timeout: 30)
    vm.wait_state("Running", timeout: 30)
    vm.agent.wait_ready(timeout: 30)
    if reseed
      vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
        unix_time_ms: (Time.now.to_f * 1000).round, ember_id: "ember-clone-#{i}")
    end
    vms << vm
  end
  vms
end

def teardown(vms)
  vms.each do |vm|
    vm.shutdown(timeout: 5)
  rescue
    vm.kill
  end
end

begin
  puts "== randomness without post_restore =="
  vms = boot_clones(n, template_dir, reseed: false)
  raw = vms.map { sample_random(_1) }
  raw.each_with_index { |s, i| puts "  clone #{i}: #{s.first} ... #{s.last[0, 16]}" }
  distinct_raw = raw.map(&:first).uniq.length
  puts "  distinct first UUIDs across #{n} clones: #{distinct_raw}"
  results["without_post_restore_distinct"] = distinct_raw
  teardown(vms)

  puts "== randomness with post_restore =="
  vms = boot_clones(n, template_dir, reseed: true)
  seeded = vms.map { sample_random(_1) }
  seeded.each_with_index { |s, i| puts "  clone #{i}: #{s.first} ... #{s.last[0, 16]}" }
  distinct_seeded = seeded.map(&:first).uniq.length
  all_values = seeded.flatten
  puts "  distinct first UUIDs across #{n} clones: #{distinct_seeded}"
  puts "  no repeated value anywhere: #{all_values.uniq.length == all_values.length}"
  results["with_post_restore_distinct"] = distinct_seeded
  results["all_samples_unique"] = (all_values.uniq.length == all_values.length)

  puts "== clock =="
  host_ms = (Time.now.to_f * 1000).round
  vms.each_with_index do |vm, i|
    g = vm.agent.call("exec", argv: ["date", "+%s%3N"], timeout_s: 20)["stdout"].strip.to_i
    puts "  clone #{i}: drift from host #{g - host_ms} ms"
    results["clock_drift_ms_#{i}"] = g - host_ms
  end

  puts "== identity =="
  vms.each_with_index do |vm, i|
    ids = vm.agent.call("exec", argv: ["sh", "-c",
      "cat /etc/machine-id; cat /proc/sys/kernel/random/boot_id; ip -6 -br addr show clnic"],
      timeout_s: 20)["stdout"].strip.split("\n")
    puts "  clone #{i}: machine-id=#{ids[0]} boot_id=#{ids[1]}"
  end

  puts "== network isolation =="
  a = vms[0].slot
  b = vms[1].slot
  # Each clone answers on its own slot address, from the host's root namespace.
  vms.each_with_index do |vm, i|
    r = Spike.sh("ping6", "-c", "1", "-W", "2", vm.slot.public_ip6, check: false)
    puts "  clone #{i} reachable at #{vm.slot.public_ip6}: #{r.include?("1 received")}"
    results["reachable_#{i}"] = r.include?("1 received")
  end
  # The guest address is identical in every slot; it must not be routable across them.
  cross = a.ns("ping6", "-c", "1", "-W", "2", b.public_ip6, check: false)
  puts "  slot A -> slot B public address: #{cross.include?("1 received") ? "REACHABLE" : "blocked"}"
  results["cross_slot_blocked"] = !cross.include?("1 received")
  # No egress at all from a guest (design doc 5.2).
  eg = vms[0].agent.call("exec", argv: ["sh", "-c",
    "timeout 3 ping6 -c1 -W2 #{b.public_ip6} >/dev/null 2>&1; echo ping=$?; " \
    "timeout 3 sh -c 'echo > /dev/tcp/1.1.1.1/443' 2>/dev/null; echo tcp4=$?"], timeout_s: 20)["stdout"]
  puts "  guest egress attempts: #{eg.strip.tr("\n", " ")} (non-zero means blocked)"
  results["guest_egress"] = eg.strip.tr("\n", " ")

  teardown(vms)
ensure
  Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
  File.write("/root/ember_spikes/out/s4_clone_safety.json", JSON.pretty_generate(results))
end
puts JSON.pretty_generate(results)
