#!/usr/bin/env ruby
# frozen_string_literal: true

# test_vm_exit_reason.rb — Reproduce VM exit reason detection on any
# Ubuntu machine with KVM, systemd, curl, and Ruby.
#
# Usage:
#   sudo ruby test_vm_exit_reason.rb
#
# What it does:
#   1. Downloads cloud-hypervisor v50 static binary + ch-remote + firmware
#   2. Downloads an Ubuntu cloud image and converts to raw
#   3. Installs a systemd unit matching Ubicloud production layout
#      (Type=simple, ExecStop=ch-remote shutdown-vmm, -v flag)
#   4. Runs three tests:
#      A) Guest ACPI shutdown (via CH API power-button)
#      B) SIGTERM (direct kill -TERM on CH pid)
#      C) SIGKILL (kill -9)
#   5. For each test, reports systemd Result and journal grep output
#
# Prerequisites:
#   - Ubuntu with KVM (/dev/kvm must exist)
#   - systemd, curl, qemu-utils (for qemu-img)
#   - Root (for systemd unit management and KVM access)
#   - ~3 GB disk space for the cloud image
#
# This script is disposable. It cleans up after itself.

require "fileutils"
require "json"
require "open3"

WORKDIR = "/tmp/ch-exit-reason-test"
UNIT_NAME = "ch-exit-test"
CH_VERSION = "v50.0"
CH_URL = "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/#{CH_VERSION}/cloud-hypervisor-static"
CH_REMOTE_URL = "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/#{CH_VERSION}/ch-remote-static"
FW_URL = "https://github.com/cloud-hypervisor/rust-hypervisor-firmware/releases/download/0.4.2/hypervisor-fw"
IMAGE_URL = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-disk-kvm.img"

def run(cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(cmd)
  unless status.success? || allow_failure
    $stderr.puts "FAILED: #{cmd}"
    $stderr.puts stderr
    exit 1
  end
  stdout.strip
end

def log(msg)
  puts "\n#{"=" * 60}\n#{msg}\n#{"=" * 60}"
end

def download(url, dest)
  return if File.exist?(dest)
  puts "  Downloading #{File.basename(dest)}..."
  run("curl -sL -o #{dest} '#{url}'")
end

def wait_for_exit(timeout: 60)
  (timeout / 2).times do
    sleep 2
    return true if run("systemctl is-active #{UNIT_NAME}", allow_failure: true) != "active"
  end
  false
end

def wait_for_boot(timeout: 30)
  timeout.times do
    sleep 1
    state = run("curl -s --unix-socket #{WORKDIR}/ch-short.sock " \
                "http://localhost/api/v1/vm.info 2>/dev/null", allow_failure: true)
    return true if state.include?('"Running"')
  end
  false
end

def systemd_result
  run("systemctl show -p Result -p InvocationID --value #{UNIT_NAME}")
    .split("\n")
    .then { |lines| {result: lines[0], invocation_id: lines[1]} }
end

def journal_grep(invocation_id)
  out = run(
    "journalctl _SYSTEMD_INVOCATION_ID=#{invocation_id} -o cat -n 50 --no-pager " \
    "| grep -m1 -oF " \
    "-e 'ACPI Shutdown signalled' " \
    "-e 'vCPU thread panicked' " \
    "-e 'VCPU generated error' " \
    "-e 'thread panicked'",
    allow_failure: true
  )
  out.empty? ? "(no match)" : out
end

def journal_tail(invocation_id, n: 5)
  run("journalctl _SYSTEMD_INVOCATION_ID=#{invocation_id} -o cat --no-pager | tail -#{n}",
    allow_failure: true)
end

def systemd_messages(n: 5)
  run("journalctl -u #{UNIT_NAME} --no-pager | grep 'systemd\\[1\\]' | tail -#{n}",
    allow_failure: true)
end

def start_vm
  run("systemctl reset-failed #{UNIT_NAME}", allow_failure: true)
  run("rm -f #{WORKDIR}/ch.sock #{WORKDIR}/ch-short.sock")
  run("systemctl start #{UNIT_NAME}")
  # The API socket path is long; symlink it for curl compatibility.
  run("ln -sf #{WORKDIR}/ch.sock #{WORKDIR}/ch-short.sock")
  unless wait_for_boot
    abort "VM failed to boot. Check: journalctl -u #{UNIT_NAME} --no-pager | tail -30"
  end
  puts "  VM is running."
end

def report(label, info)
  puts <<~REPORT

    --- #{label} ---
    systemd Result:  #{info[:result]}
    InvocationID:    #{info[:invocation_id]}
    Journal grep:    #{info[:grep]}
    systemd message: #{info[:systemd_msg]}
    CH tail:
    #{info[:ch_tail].gsub(/^/, "      ")}
  REPORT
end

def run_test(label)
  start_vm
  # Let the guest OS finish booting (cloud-init, acpid, etc.)
  puts "  Waiting 20s for guest to settle..."
  sleep 20

  yield

  unless wait_for_exit
    puts "  WARNING: VM did not exit within timeout"
  end
  sleep 1

  info = systemd_result
  info[:grep] = journal_grep(info[:invocation_id])
  info[:ch_tail] = journal_tail(info[:invocation_id])
  info[:systemd_msg] = systemd_messages(n: 3)
  report(label, info)
  info
end

# ── Preflight ──────────────────────────────────────────────

abort "Must run as root (need systemd and KVM access)" unless Process.uid == 0
abort "/dev/kvm not found — KVM required" unless File.exist?("/dev/kvm")

unless system("which qemu-img > /dev/null 2>&1")
  puts "Installing qemu-utils..."
  run("apt-get install -y qemu-utils")
end

# ── Setup ──────────────────────────────────────────────────

log "Setting up in #{WORKDIR}"
FileUtils.mkdir_p(WORKDIR)

download(CH_URL, "#{WORKDIR}/cloud-hypervisor")
FileUtils.chmod(0o755, "#{WORKDIR}/cloud-hypervisor")

download(CH_REMOTE_URL, "#{WORKDIR}/ch-remote")
FileUtils.chmod(0o755, "#{WORKDIR}/ch-remote")

download(FW_URL, "#{WORKDIR}/hypervisor-fw")

download(IMAGE_URL, "#{WORKDIR}/guest.qcow2")

unless File.exist?("#{WORKDIR}/guest.raw")
  puts "  Converting qcow2 → raw..."
  run("qemu-img convert -f qcow2 -O raw #{WORKDIR}/guest.qcow2 #{WORKDIR}/guest.raw")
end

puts "  CH version: #{run("#{WORKDIR}/cloud-hypervisor --version")}"

# ── Install systemd unit (matches production layout) ──────

# Production uses:
#   ExecStart=<ch-bin> -v --api-socket path=<sock> --kernel <fw> ...
#   ExecStop=<ch-remote> --api-socket <sock> shutdown-vmm
#   --serial file=<log>  (serial to file, not tty)
#
# The -v flag is critical: without it, CH does not log INFO-level
# messages (including "ACPI Shutdown signalled") to journald.

unit = <<~UNIT
  [Unit]
  Description=CH exit reason test VM

  [Service]
  Type=simple
  ExecStartPre=/usr/bin/rm -f #{WORKDIR}/ch.sock
  ExecStart=#{WORKDIR}/cloud-hypervisor -v \\
    --api-socket path=#{WORKDIR}/ch.sock \\
    --firmware #{WORKDIR}/hypervisor-fw \\
    --cpus boot=1 \\
    --memory size=512M \\
    --disk path=#{WORKDIR}/guest.raw \\
    --net tap=,mac=12:34:56:78:90:ab \\
    --serial file=#{WORKDIR}/serial.log \\
    --console off
  ExecStop=#{WORKDIR}/ch-remote --api-socket #{WORKDIR}/ch.sock shutdown-vmm
UNIT

File.write("/etc/systemd/system/#{UNIT_NAME}.service", unit)
run("systemctl daemon-reload")
puts "  Installed #{UNIT_NAME}.service"

# ── Tests ─────────────────────────────────────────────────

results = []

log "Test A: Guest ACPI shutdown (power button via CH API)"
results << run_test("ACPI Shutdown") do
  puts "  Sending ACPI power button..."
  run("curl -s --unix-socket #{WORKDIR}/ch-short.sock " \
      "-X PUT http://localhost/api/v1/vm.power-button",
    allow_failure: true)
end

log "Test B: SIGTERM (kill -TERM on CH process)"
results << run_test("SIGTERM") do
  pid = run("systemctl show -p MainPID --value #{UNIT_NAME}")
  puts "  Sending SIGTERM to PID #{pid}..."
  Process.kill("TERM", pid.to_i)
end

log "Test C: SIGKILL (kill -9 on CH process)"
results << run_test("SIGKILL") do
  pid = run("systemctl show -p MainPID --value #{UNIT_NAME}")
  puts "  Sending SIGKILL to PID #{pid}..."
  Process.kill("KILL", pid.to_i)
end

# ── Summary ───────────────────────────────────────────────

log "Summary"

puts <<~TABLE
  | Test             | systemd Result | Journal grep match         |
  |------------------|----------------|----------------------------|
TABLE

labels = ["ACPI Shutdown", "SIGTERM", "SIGKILL"]
results.each_with_index do |r, i|
  printf("  | %-16s | %-14s | %-26s |\n", labels[i], r[:result], r[:grep])
end

puts <<~ANALYSIS

  Interpretation:
  - "exit-code" means CH exited on its own AND ExecStop (ch-remote)
    failed because the socket was already gone. This is the AMBIGUOUS
    case — need journal grep to distinguish guest ACPI shutdown from
    SIGTERM or other clean exits.
  - "signal" means the process was forcibly killed (SIGKILL, OOM).
    Unambiguous — always page-worthy.
  - "success" would mean ExecStop (ch-remote shutdown-vmm) ran
    successfully — i.e. an operator intentionally stopped the VM.
    (Not tested here because systemctl stop runs ExecStop itself.)
ANALYSIS

# ── Cleanup ───────────────────────────────────────────────

log "Cleanup"
run("systemctl stop #{UNIT_NAME}", allow_failure: true)
run("systemctl reset-failed #{UNIT_NAME}", allow_failure: true)
run("rm -f /etc/systemd/system/#{UNIT_NAME}.service")
run("systemctl daemon-reload")
run("rm -f #{WORKDIR}/ch-short.sock")
puts "  Unit removed. Image/binaries left in #{WORKDIR} for re-runs."
puts "  To fully clean up: rm -rf #{WORKDIR}"
