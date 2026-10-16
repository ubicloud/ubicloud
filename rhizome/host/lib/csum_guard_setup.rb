# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "json"

# Drops IPv4 packets with bad checksum metadata at the VM taps, applying
# the test from upstream 6785011f8b16 on hosts that run an older kernel.
# The prebuilt CO-RE object comes from the ubicloud/csum-guard release
# that VERSION pins, and tc loads it, so the host needs no compiler and
# no bpftool.
#
# The guard is on for a host while the object for VERSION is in DIR.
# install places it and attaches to every existing VM tap; uninstall
# removes it and detaches.
# VmSetup attaches new and recreated taps through maybe_attach_vm, so taps
# rebuilt after a reboot get the guard back without a boot unit.
class CsumGuardSetup
  VERSION = "0.1.0"

  # The object is BPF bytecode, so one asset serves every architecture.
  OBJECT_SHA256 = "931edb72463ef0fa4028568fe3dcfa2e694d2eb14622bac77d69652fe12dcae3"

  # The program reads the skb checksum fields through bpf_cast_to_kern_ctx,
  # which needs 6.3.
  MIN_KERNEL = [6, 3].freeze

  DIR = "/opt/csum-guard"
  LOCK_PATH = "/run/lock/csum-guard.lock"
  NETNS_DIR = "/var/run/netns"
  PROBE_NETNS = "csum-guard-probe"

  # A high preference keeps this filter apart from filters that other code
  # adds at the default preferences.
  TC_PREF = "49152"

  def self.maybe_attach_vm(netns, taps)
    new.maybe_attach_vm(netns, taps)
  end

  def object
    File.join(DIR, "csum_guard-#{VERSION}.bpf.o")
  end

  def object_url
    "https://github.com/ubicloud/csum-guard/releases/download/v#{VERSION}/csum_guard.bpf.o"
  end

  # The lock only keeps install and uninstall apart. Walking every tap of a
  # busy host takes long, so VM creation never waits for it.
  def install
    check_kernel
    with_lock do
      download_object
      each_vm_tap { |netns, tap| attach(netns, tap, object) }
    end
  end

  def uninstall
    with_lock do
      FileUtils.rm_f(object)
      each_vm_tap { |netns, tap| detach(netns, tap) }
    end
  end

  # A no-op until install has run on this host: without the object this
  # returns before running any command, taking any lock, or writing any
  # file.
  #
  # A VM created during an install is guarded by this or by the install's
  # walk. One created during an uninstall can keep the guard, which is
  # harmless, and running uninstall again removes it; if the uninstall
  # removes the object while tc loads it, the VM gets no guard.
  def maybe_attach_vm(netns, taps)
    return unless File.exist?(object)

    taps.each { |tap| attach(netns, tap, object) }
  rescue CommandFail
    raise if File.exist?(object)
  end

  def check_kernel
    release = r("uname -r").strip
    unless (m = /\A(\d+)\.(\d+)/.match(release))
      fail "Cannot parse kernel release #{release.inspect}"
    end
    return if ([m[1].to_i, m[2].to_i] <=> MIN_KERNEL) >= 0

    fail "Kernel #{release} is older than #{MIN_KERNEL.join(".")}, which the checksum guard requires"
  end

  def with_lock
    File.open(LOCK_PATH, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  # The object's presence turns the guard on, so it reaches its path only
  # once it matches its digest and loads on this kernel.
  def download_object
    return if File.exist?(object)

    FileUtils.mkdir_p(DIR)
    safe_write_to_file(object) do |f|
      unless curl_file(object_url, f.path) == OBJECT_SHA256
        fail "Invalid SHA-256 digest"
      end
      probe(f.path)
    end
  end

  # VmSetup fails a VM whose taps cannot get the guard, so prove that the
  # object loads before any VM depends on it, also on a host that has no
  # VM yet.
  def probe(obj)
    remove_probe_netns
    r "ip", "netns", "add", PROBE_NETNS
    r "ip", "-n", PROBE_NETNS, "tuntap", "add", "dev", "probe", "mode", "tap"
    attach(PROBE_NETNS, "probe", obj)
  ensure
    remove_probe_netns
  end

  def remove_probe_netns
    r "ip", "netns", "del", PROBE_NETNS, expect: [0, 1]
  end

  # VmSetup creates every tap in a named namespace. Attaching to a tap that
  # is not a VM's would be harmless, as well-formed packets pass. VMs are
  # created and deleted during a walk, so a namespace or tap that is gone
  # by its turn is skipped.
  def each_vm_tap
    JSON.parse(r("ip", "-j", "netns", "list")).each do |ns|
      netns = ns.fetch("name")
      links = begin
        r("ip", "-n", netns, "-j", "link", "show", "type", "tun")
      rescue CommandFail
        raise if File.exist?(File.join(NETNS_DIR, netns))

        next
      end
      JSON.parse(links).each do |link|
        tap = link.fetch("ifname")
        begin
          yield netns, tap
        rescue CommandFail
          raise unless tap_gone?(netns, tap)
        end
      end
    end
  end

  # ip exits 1 for a missing tap and 255 for a missing namespace.
  def tap_gone?(netns, tap)
    r("ip", "-n", netns, "link", "show", "dev", tap, expect: [0, 1, 255]).empty?
  end

  def attach(netns, tap, obj)
    r "tc", "-n", netns, "qdisc", "replace", "dev", tap, "clsact"
    r "tc", "-n", netns, "filter", "replace", "dev", tap, "ingress", "pref", TC_PREF, "handle", "1",
      "bpf", "direct-action", "object-file", obj, "section", "tc"
  end

  # tc exits 2 when the filter or the clsact qdisc is already gone. The
  # empty clsact stays, as other filters may use it.
  def detach(netns, tap)
    r "tc", "-n", netns, "filter", "del", "dev", tap, "ingress", "pref", TC_PREF, expect: [0, 2]
  end
end
