#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S1, part 1: restore latency (design doc section 12).
#
# Pass condition from the design: p50 <= 250 ms from process start to the guest
# agent answering, at 512 MiB, over 50 runs; ondemand measured for comparison.
#
#   ruby s1_restore.rb [template] [runs]

require_relative "lib/ember"

template = ARGV[0] || "t512"
runs = Integer(ARGV[1] || 50)
template_dir = File.join(Spike::TEMPLATES, template)
raise "no template at #{template_dir}" unless File.directory?(template_dir)

SLOT_BASE = 100

def one_run(slot, template_dir, mode, prefault)
  vm = Spike::Vm.new(slot)
  phases = {}
  t0 = Spike.now
  dir = vm.prepare_restore_dir(template_dir)
  phases[:prepare] = Spike.ms(t0)

  t1 = Spike.now
  vm.restore(dir, memory_restore_mode: mode, prefault:)
  vm.wait_api_socket(timeout: 30)
  phases[:api] = Spike.ms(t1)
  vm.wait_state("Running", timeout: 30)
  phases[:running] = Spike.ms(t1)
  vm.agent.wait_ready(timeout: 30)
  phases[:agent] = Spike.ms(t1)
  hello = vm.agent.call("hello")
  phases[:hello] = Spike.ms(t1)
  vm.agent.call("hello")
  phases[:hello2] = Spike.ms(t1)
  # How much guest time elapsed since the snapshot was taken, i.e. how much of
  # the wall clock above the guest actually spent executing.
  phases[:guest_ran] = ((hello["uptime_s"] - SNAPSHOT_UPTIME) * 1000).round(1)
  [phases, vm, hello]
end

SNAPSHOT_UPTIME = JSON.parse(File.read(File.join(template_dir, "spike-meta.json")))["snapshot_uptime_s"] || 0.0

PHASES = %i[prepare api running agent hello hello2 guest_ran].freeze

modes = [["copy", false], ["copy", true], ["ondemand", false], ["ondemand", true]]
results = {}

modes.each do |mode, prefault|
  label = "#{mode}#{"+prefault" if prefault}"
  samples = Hash.new { |h, k| h[k] = [] }
  errors = 0
  runs.times do |i|
    slot = Spike::Slot.new(SLOT_BASE + (i % 4))
    slot.create unless slot.exists?
    vm = nil
    begin
      phases, vm, = one_run(slot, template_dir, mode, prefault)
      phases.each { |k, v| samples[k] << v }
    rescue => e
      errors += 1
      warn "run #{i} (#{label}) failed: #{e.message}"
    ensure
      vm&.kill
    end
  end
  results[label] = [samples, errors]
  puts "== #{label} (#{runs} runs, #{errors} errors) =="
  PHASES.each do |k|
    puts "  " + Spike.summarize(k.to_s, samples[k])
  end
end

(SLOT_BASE...(SLOT_BASE + 4)).each { Spike::Slot.new(_1).destroy }

puts "\nlegend: api=vmm answers, running=restore complete and resumed, agent=guest agent accepts vsock, hello=first command answered"
File.write("/root/ember_spikes/out/s1_restore.json",
  JSON.pretty_generate(results.transform_values { |(s, e)| {"samples" => s, "errors" => e} }))
