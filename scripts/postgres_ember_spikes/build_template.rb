#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Build a template memory snapshot (design doc 4.3): cold-boot the ember root
# image with no data disk, wait for the guest agent, pause, snapshot.
#
require "time"
#   ruby build_template.rb [name] [memory_mib]

require_relative "lib/ember"

name = ARGV[0] || "t512"
memory_mib = Integer(ARGV[1] || 512)
root_image = "#{Spike::IMAGES}/cell-root-18-agent.raw"
template_dir = File.join(Spike::TEMPLATES, name)

slot = Spike::Slot.new(999)
slot.create
vm = Spike::Vm.new(slot)

FileUtils.rm_rf(template_dir)
FileUtils.mkdir_p(template_dir)

begin
  t0 = Spike.now
  vm.boot(root_image:, memory_mib:)
  vm.wait_api(timeout: 30)
  puts "api socket ready in #{Spike.ms(t0)} ms"
  vm.agent.wait_ready(timeout: 180)
  boot_ms = Spike.ms(t0)
  hello = vm.agent.call("hello")
  puts "agent up in #{boot_ms} ms: #{hello.inspect}"

  # A snapshot taken while systemd is still starting units makes every restored
  # clone replay the tail of boot, which dominates resume latency. Wait for the
  # guest to finish booting and go quiet before pausing it.
  deadline = Spike.now + 120
  state = nil
  quiet = 0
  loop do
    out = vm.agent.call("exec", argv: ["sh", "-c",
      "systemctl is-system-running; systemctl list-jobs --no-legend | wc -l"], timeout_s: 30)["stdout"]
    state, jobs = out.split("\n")
    quiet = (jobs.to_i.zero? && state != "starting" && state != "initializing") ? quiet + 1 : 0
    break if quiet >= 3
    raise "guest never went quiet (state #{state.inspect}, #{jobs.to_i} jobs)" if Spike.now > deadline
    sleep 0.2
  end
  puts "guest quiet in state #{state.inspect} at #{Spike.ms(t0)} ms"
  sleep 2

  # Warm the binaries the restored clone will exec immediately.
  vm.agent.call("exec", argv: ["/usr/lib/postgresql/18/bin/postgres", "--version"], timeout_s: 30)
  vm.agent.call("exec", argv: ["sync"], timeout_s: 30)
  idle = vm.agent.call("exec", argv: ["sh", "-c", "cat /proc/loadavg; systemctl list-jobs --no-legend | wc -l"], timeout_s: 30)
  puts "guest at snapshot: #{idle["stdout"].strip.gsub("\n", " | ")}"
  snapshot_uptime = vm.agent.call("hello")["uptime_s"]
  vm.agent.close

  puts "pausing"
  vm.ch_remote("pause")
  t1 = Spike.now
  vm.ch_remote("snapshot", "file://#{template_dir}")
  puts "snapshot took #{Spike.ms(t1)} ms"
  vm.ch_remote("shutdown", check: false)
  vm.kill
ensure
  vm.kill
  slot.destroy
end

puts "template files:"
Dir.children(template_dir).sort.each do |f|
  p = File.join(template_dir, f)
  puts format("  %-16s apparent=%-10s actual=%s", f,
    File.size(p), `du -sh --apparent-size #{p}`.split.first)
end
meta = {"name" => name, "memory_mib" => memory_mib, "snapshot_uptime_s" => snapshot_uptime, "root_image" => root_image,
        "ch_version" => "53.0", "built_at" => Time.now.utc.iso8601,
        "cpu_signature" => File.read("/proc/cpuinfo")[/vendor_id.*\n.*\n.*\n.*\n/].to_s.split("\n").map { _1.split(":").last.strip }.join("-")}
File.write(File.join(template_dir, "spike-meta.json"), JSON.pretty_generate(meta))
puts "template ready at #{template_dir}"
