# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "../../common/lib/network"
require "fileutils"

# Installs the route-following NDP proxy on hosts whose provider treats the
# host's IPv6 network as on-link. The eBPF program and everything that
# configures it live in the host-ebpf binary; this class owns when to install
# it, and the systemd units that re-apply and watch it.
class NdpProxySetup
  VERSION = "0.1.1"

  PACKAGE_SHA256 = Arch.render(
    x64: "2d0fbfd0f56be9a4be6b29229717edbf9d985da1536c1619bdb57e4f7e7e322d",
    arm64: "674d10ccd1d697345a5b814db47e10caf04e46d5501227986d3fa2f475521fef",
  )

  # TCX links, which the program attaches with, need 6.6.
  MIN_KERNEL = [6, 6].freeze

  UNIT_DIR = "/etc/systemd/system"
  SETUP_BIN = "/home/rhizome/host/bin/setup-ndp-proxy"
  LOCK_PATH = "/run/lock/ndp-proxy.lock"

  def initialize(net6)
    @net6 = net6
  end

  def install_dir
    "/opt/host-ebpf-#{VERSION}"
  end

  def bin
    File.join(install_dir, "host-ebpf")
  end

  def package_url
    arch = Arch.render(x64: "x86_64", arm64: "arm64")
    "https://github.com/ubicloud/host-ebpf/releases/download/v#{VERSION}/host-ebpf_Linux_#{arch}.tar.gz"
  end

  def install
    check_kernel
    with_lock { download_binary }
    write_units
    r "systemctl daemon-reload"
    r "systemctl enable ndp-proxy.service"
    # Starting an active RemainAfterExit oneshot is a no-op, so restart to
    # re-run apply against a new binary or a corrected net6.
    r "systemctl restart ndp-proxy.service"
    r "systemctl enable --now ndp-proxy-watch.timer"
  end

  # host-ebpf refuses old kernels at apply, but that surfaces only as a
  # failed unit; check up front so the install error names the cause.
  def check_kernel
    release = r("uname -r").strip
    unless (m = /\A(\d+)\.(\d+)/.match(release))
      fail "Cannot parse kernel release #{release.inspect}"
    end
    return if ([m[1].to_i, m[2].to_i] <=> MIN_KERNEL) >= 0

    fail "Kernel #{release} is older than #{MIN_KERNEL.join(".")}, which the ndp proxy requires"
  end

  # The boot unit, the watch tick, and a reinstall can overlap. host-ebpf pins
  # its maps and link separately, and the download shares one archive path,
  # so everything that touches either runs under one host-wide lock.
  def with_lock
    File.open(LOCK_PATH, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  # Extraction goes through a temporary path because the units resolve bin
  # from VERSION on every boot and every tick, so a truncated file left at
  # that path by an interrupted run would be trusted forever.
  def download_binary
    return if File.exist?(bin)

    FileUtils.mkdir_p(install_dir)
    tarball = File.join(install_dir, "host-ebpf.tar.gz")
    safe_write_to_file(tarball) do |f|
      unless curl_file(package_url, f.path) == PACKAGE_SHA256
        fail "Invalid SHA-256 digest"
      end
    end
    safe_write_to_file(bin) do |f|
      r "tar -xzOf :tarball host-ebpf > :path", tarball: tarball, path: f.path
      FileUtils.chmod("a+x", f.path)
    end
    FileUtils.rm_f(tarball)
  end

  # Rhizome reaches already-provisioned hosts, but HostNexus#prep does not
  # run again on them, so the units fetch the version they were written for
  # rather than assuming an install placed it.
  def apply
    with_lock do
      download_binary
      r bin, "ndp-proxy", "apply", "-uplink", uplink, "-prefix", @net6
    end
  end

  def verify
    with_lock do
      download_binary
      r bin, "ndp-proxy", "verify", "-uplink", uplink, "-prefix", @net6, "-heal"
    end
  end

  # Neighbor discovery is IPv6 only, so prefer that table. Providers that
  # deliver a prefix on-link often supply no IPv6 default route at all,
  # and a host reaching both families does so over one uplink.
  def uplink
    default_route_device(r("ip -6 -j route"), r("ip -j route"))
  end

  # oneshot units have no start timeout by default, and a stalled download
  # would hold the watch unit in activating and skip every later tick.
  def write_units
    safe_write_to_file(File.join(UNIT_DIR, "ndp-proxy.service"), <<UNIT)
[Unit]
Description=Route-following NDP proxy for delegated VM prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=10min
WorkingDirectory=/home/rhizome
ExecStart=#{SETUP_BIN} apply #{@net6}

[Install]
WantedBy=multi-user.target
UNIT
    safe_write_to_file(File.join(UNIT_DIR, "ndp-proxy-watch.service"), <<UNIT)
[Unit]
Description=Re-attach the NDP proxy if its uplink state drifted

[Service]
Type=oneshot
TimeoutStartSec=10min
WorkingDirectory=/home/rhizome
ExecStart=#{SETUP_BIN} verify #{@net6}
UNIT
    safe_write_to_file(File.join(UNIT_DIR, "ndp-proxy-watch.timer"), <<UNIT)
[Unit]
Description=Periodic NDP proxy attachment check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
  end
end
