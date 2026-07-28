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
  VERSION = "0.1.0"

  PACKAGE_SHA256 = Arch.render(
    x64: "05835a138677ea3899e7e257deb4e2886ea25789ba00a20eceedbc5e7ea89646",
    arm64: "28631e4abb6b6300743b7883f2afbb2ccca311a5d47a6c780025a886819e7395",
  )

  UNIT_DIR = "/etc/systemd/system"
  SETUP_BIN = "/home/rhizome/host/bin/setup-ndp-proxy"

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
    download_binary
    write_units
    r "systemctl daemon-reload"
    r "systemctl enable ndp-proxy.service"
    # Starting an active RemainAfterExit oneshot is a no-op, so restart to
    # re-run apply against a new binary or a corrected net6.
    r "systemctl restart ndp-proxy.service"
    r "systemctl enable --now ndp-proxy-watch.timer"
  end

  # Extraction goes through a temporary path because the units resolve bin
  # from VERSION on every boot and every tick, so a truncated file left at
  # that path by an interrupted run would be trusted forever.
  def download_binary
    return if File.exist?(bin)

    FileUtils.mkdir_p(install_dir)
    tarball = "/tmp/host-ebpf-#{VERSION}.tar.gz"
    safe_write_to_file(tarball) do |f|
      unless curl_file(package_url, f.path) == PACKAGE_SHA256
        fail "Invalid SHA-256 digest"
      end
    end
    safe_write_to_file(bin) do |f|
      r "tar -xzOf #{tarball} host-ebpf > #{f.path}"
      FileUtils.chmod("a+x", f.path)
    end
    FileUtils.rm_f(tarball)
  end

  # Rhizome reaches already-provisioned hosts, but HostNexus#prep does not
  # run again on them, so the units fetch the version they were written for
  # rather than assuming an install placed it.
  def apply
    download_binary
    r "#{bin} ndp-proxy apply -uplink #{uplink} -prefix #{@net6}"
  end

  def verify
    download_binary
    r "#{bin} ndp-proxy verify -uplink #{uplink} -prefix #{@net6} -heal"
  end

  # Neighbor discovery is IPv6 only, and a host can route the two families
  # out different devices.
  def uplink
    default_route_device(r("ip -6 -j route"))
  end

  def write_units
    safe_write_to_file(File.join(UNIT_DIR, "ndp-proxy.service"), <<UNIT)
[Unit]
Description=Route-following NDP proxy for delegated VM prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
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
WorkingDirectory=/home/rhizome
ExecStart=#{SETUP_BIN} verify #{@net6}
UNIT
    safe_write_to_file(File.join(UNIT_DIR, "ndp-proxy-watch.timer"), <<UNIT)
[Unit]
Description=Periodic NDP proxy attachment check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT
  end
end
