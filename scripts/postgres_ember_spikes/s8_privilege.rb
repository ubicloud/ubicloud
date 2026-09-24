#!/usr/bin/env ruby
# frozen_string_literal: true

#
# The design runs cloud-hypervisor as a per-slot unix user (5.2), but every
# other spike here runs as root. Check what a non-root slot user actually needs
# in order to restore with memory_restore_mode=ondemand and talk vsock.
#
#   ruby s8_privilege.rb [template]

require "etc"
require_relative "lib/ember"

template = ARGV[0] || "t512"
template_dir = File.join(Spike::TEMPLATES, template)
SLOT_N = 500
USER = "emslot0500"
UID = 60_500

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
report = {}

def device_mode(path)
  format("%04o %s:%s", File.stat(path).mode & 0o7777,
    Etc.getpwuid(File.stat(path).uid).name, Etc.getgrgid(File.stat(path).gid).name)
rescue
  "missing"
end

puts "== host defaults =="
%w[/dev/kvm /dev/vhost-vsock /dev/userfaultfd /dev/net/tun].each do |d|
  puts format("  %-20s %s", d, device_mode(d))
  report["mode_#{File.basename(d)}"] = device_mode(d)
end
uffd_sysctl = File.read("/proc/sys/vm/unprivileged_userfaultfd").strip
puts "  vm.unprivileged_userfaultfd = #{uffd_sysctl}"
report["unprivileged_userfaultfd"] = uffd_sysctl

# Create the slot user the way prep-host would.
Spike.sh("userdel", USER, check: false)
Spike.sh("useradd", "--uid", UID.to_s, "--no-create-home", "--home-dir", "/vm/#{USER}",
  "--shell", "/usr/sbin/nologin", "--groups", "kvm", USER, check: false)

slot = Spike::Slot.new(SLOT_N)
slot.create
# The tap must belong to the slot user, as vm_setup.rb does for a VM.
slot.ns("ip", "link", "del", "cltap")
slot.ns("ip", "tuntap", "add", "dev", "cltap", "mode", "tap", "user", UID.to_s)
slot.ns("ip", "addr", "add", "#{Spike::GATEWAY_IP6}/64", "dev", "cltap", "nodad")
slot.ns("ip", "link", "set", "cltap", "up")

vm = Spike::Vm.new(slot)
dir = vm.prepare_restore_dir(template_dir)
FileUtils.chown_R(USER, USER, slot.dir)
# The template itself stays root-owned and read-only, shared by every slot.
Spike.sh("chmod", "-R", "a+rX", File.join(Spike::TEMPLATES, template))

# Keep the hypervisor log; cleanup wipes /vm.
def dump_log(vm, tag)
  out = "/root/ember_spikes/out/ch-#{tag}.log"
  FileUtils.cp(vm.ch_log, out) if File.exist?(vm.ch_log)
  puts File.read(vm.ch_log).lines.last(12).map { "    #{_1}" }.join
rescue SystemCallError
  puts "    (no log)"
end

def try_restore(vm, dir, mode, user, uid)
  vm.clean_paths
  # Hand the whole slot directory to whoever is about to run in it; a previous
  # attempt as another user leaves files behind.
  FileUtils.chown_R(user, user, vm.slot.dir)
  log = File.open(vm.ch_log, "a")
  pid = Process.spawn("ip", "netns", "exec", vm.slot.netns,
    "setpriv", "--reuid=#{uid}", "--regid=#{uid}", "--init-groups",
    Spike::CH_BIN, "-v", "--api-socket", "path=#{vm.api_sock}",
    "--restore", "source_url=file://#{dir},memory_restore_mode=#{mode},resume=true",
    out: log, err: log)
  log.close
  vm.instance_variable_set(:@pid, pid)
  t = Spike.now
  vm.wait_api_socket(timeout: 20)
  vm.wait_state("Running", timeout: 20)
  vm.agent.wait_ready(timeout: 20)
  who = vm.agent.call("hello")
  ms = Spike.ms(t)
  [true, ms, who]
rescue => e
  [false, nil, e.message.lines.first.to_s.strip]
ensure
  begin
    vm.agent.close
  rescue
    nil
  end
end

begin
  puts "== control: same slot and restore dir, as root =="
  okr, msr, = try_restore(vm, dir, "ondemand", "root", 0)
  puts "  #{okr ? "OK in #{msr} ms" : "FAILED"}"
  report["ondemand_root_same_slot"] = {"ok" => okr, "ms" => msr}
  vm.kill

  puts "== restore as #{USER} (uid #{UID}), ondemand, with prep_host's relaxed policy =="
  ok, ms, info = try_restore(vm, dir, "ondemand", USER, UID)
  owner = ok ? Spike.sh("sh", "-c", "ps -o user= -p #{vm.pid}").strip : "-"
  puts "  #{ok ? "OK in #{ms} ms as user #{owner}" : "FAILED: #{info}"}"
  dump_log(vm, "ondemand_relaxed")
  report["ondemand_nonroot"] = {"ok" => ok, "ms" => ms}
  vm.kill

  puts "== same, but with /dev/userfaultfd restored to the Ubuntu default =="
  Spike.sh("chmod", "0600", "/dev/userfaultfd")
  Spike.sh("sysctl", "-q", "-w", "vm.unprivileged_userfaultfd=0")
  ok2, ms2, info2 = try_restore(vm, dir, "ondemand", USER, UID)
  puts "  #{ok2 ? "OK in #{ms2} ms" : "FAILED: #{info2}"}"
  dump_log(vm, "ondemand_default")
  report["ondemand_nonroot_default_policy"] = {"ok" => ok2}
  vm.kill

  puts "== copy mode as #{USER} under the default policy =="
  ok3, ms3, = try_restore(vm, dir, "copy", USER, UID)
  dump_log(vm, "copy_default")
  report["copy_nonroot_default_policy"] = {"ok" => ok3, "ms" => ms3}
  vm.kill
ensure
  vm.kill
  Spike.sh("chmod", "0666", "/dev/userfaultfd", check: false)
  Spike.sh("sysctl", "-q", "-w", "vm.unprivileged_userfaultfd=1", check: false)
  Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
  Spike.sh("userdel", USER, check: false)
  File.write("/root/ember_spikes/out/s8_privilege.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
end
