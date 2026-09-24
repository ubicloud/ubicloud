#!/usr/bin/env ruby
# frozen_string_literal: true

# Template for the agentless image: cold boot, wait for the guest to report
# on the serial port that boot has settled, pause, snapshot.
#   ruby build_template_agentless.rb name root_image [memory_mib]
require "time"
require_relative "lib/ember"

name, root_image = ARGV[0], ARGV[1]
memory_mib = Integer(ARGV[2] || 512)
template_dir = File.join(Spike::TEMPLATES, name)
slot = Spike::Slot.new(998)
slot.create
vm = Spike::Vm.new(slot)
FileUtils.rm_rf(template_dir)
FileUtils.mkdir_p(template_dir)
begin
  t0 = Spike.now
  vm.boot(root_image:, memory_mib:)
  vm.wait_api(timeout: 30)
  line = nil
  loop do
    line = File.exist?(vm.serial_log) && File.read(vm.serial_log, mode: "rb")[/CELL-TEMPLATE-READY[^\r\n]*/]
    break if line
    raise "guest never settled" if Spike.ms(t0) > 180_000
    sleep 0.1
  end
  puts "#{line} at #{Spike.ms(t0).round} ms"
  sleep 3
  vm.ch_remote("pause")
  t1 = Spike.now
  vm.ch_remote("snapshot", "file://#{template_dir}")
  puts "snapshot took #{Spike.ms(t1).round} ms"
  vm.ch_remote("shutdown", check: false)
ensure
  vm.kill
  slot.destroy
end
File.write(File.join(template_dir, "spike-meta.json"), JSON.pretty_generate(
  "name" => name, "memory_mib" => memory_mib, "root_image" => root_image, "built_at" => Time.now.utc.iso8601,
))
