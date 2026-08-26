# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "logger"

class PostgresSetup
  # Per-service GOMEMLIMIT targets, sum kept under system-go_services.slice MemoryHigh=2G
  GO_SERVICES = {
    "prometheus" => "1024MiB",
    "wal-g" => "448MiB",
    "postgres_exporter" => "384MiB",
    "node_exporter" => "128MiB",
  }.freeze

  def initialize(version)
    @version = version
  end

  def install_packages
    # Check if the packages exist in the cache, if so, install them.
    if File.exist?("/var/cache/postgresql-packages/#{@version}")
      r "sudo", "install-postgresql-packages", @version.to_s
    end
  end

  def configure_memory_overcommit(strict: false)
    if strict
      total_mem_kb = File.read("/proc/meminfo").match(/MemTotal:\s+(\d+)/)[1].to_i
      # 25% of memory is reserved for hugepages, which do not count towards the
      # commit limit, so only the remaining 75% is available for overcommit.
      non_hugepage_mem_kb = total_mem_kb * 0.75
      overcommit_kbytes = (non_hugepage_mem_kb * 0.8 + 2 * 1048576).round
      safe_write_to_file("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=#{overcommit_kbytes}\n")
    else
      r "sudo rm -f /etc/sysctl.d/99-overcommit.conf"
    end

    r "sudo sysctl --system"
  end

  def configure_tcp_keepalive
    safe_write_to_file("/etc/sysctl.d/99-tcp-keepalive.conf", <<~SYSCTL)
      net.ipv4.tcp_keepalive_time=30
      net.ipv4.tcp_keepalive_probes=3
      net.ipv4.tcp_keepalive_intvl=10
    SYSCTL
    r "sudo sysctl --system"
  end

  JOURNALD_CONF_PATH = "/etc/systemd/journald.conf.d/50-persistent.conf"

  # The root filesystem is 16 GiB (Config.postgres_boot_disk_size_gib) and the
  # control plane pages at 90% of it. What sits there besides this journal:
  # about 6 G of image, a 4 G swapfile on the hobby sizes, and up to 1 G of
  # Prometheus TSDB (--storage.tsdb.retention.size). A 4G cap here pushed every
  # hobby server over the page line as its journal filled. 1G holds roughly a
  # month of entries once configure_root_disk has quieted the writers below,
  # and 64M files let vacuuming reclaim in small steps. SplitMode=none keeps
  # journald from carrying one 8 MB-minimum file per UID that ever logged.
  JOURNALD_CONF = <<~JOURNALD
    [Journal]
    Storage=persistent
    SystemMaxUse=1G
    SystemMaxFileSize=64M
    MaxRetentionSec=1month
    SplitMode=none
    Compress=yes
    ForwardToSyslog=no
  JOURNALD

  # Every file the stock rsyslog config writes, with its rotated and compressed
  # generations. Once rsyslog is gone nothing writes, rotates or reads them.
  RSYSLOG_LOGS_GLOB = "/var/log/{syslog,auth.log,kern.log,daemon.log,user.log,lpr.log,cron.log,debug,messages,mail.log,mail.info,mail.warn,mail.err}*"

  # rsyslog duplicates the journal into /var/log with no size ceiling, so the
  # root filesystem fills. The current image drops it for a capped persistent
  # journal at build time; servers built before that image need the same end
  # state applied in place, including reclaiming what rsyslog already wrote.
  def configure_journald
    unless File.exist?(JOURNALD_CONF_PATH) && File.read(JOURNALD_CONF_PATH) == JOURNALD_CONF
      r "mkdir", "-p", File.dirname(JOURNALD_CONF_PATH)
      safe_write_to_file(JOURNALD_CONF_PATH, JOURNALD_CONF)
      r "systemctl", "restart", "systemd-journald"
      # A lowered cap only bites at the next rotation; rotate and vacuum now so
      # the space comes back with the configure that lowered it.
      r "journalctl", "--rotate"
      r "journalctl", "--vacuum-size=1G"
    end

    return unless File.exist?("/usr/sbin/rsyslogd")

    # postrm takes /etc/logrotate.d/rsyslog with it, so the stale weekly config
    # does not outlive the daemon.
    r "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "purge", "-y", "rsyslog"

    FileUtils.rm_f(Dir.glob(RSYSLOG_LOGS_GLOB))
  end

  # Everything below keeps the root filesystem within its budget: the journal
  # writers that fill it and the dead weight the image left on it. Applied from
  # bin/configure, like configure_journald, so it reaches every server.
  def configure_root_disk(aws:)
    quiet_periodic_units
    # nil means the control plane predates the flag; leave the agent alone
    # rather than guess where the server runs.
    disable_guardduty if aws == false
    purge_snapd
    purge_stale_kernels
    clean_package_caches
  end

  # Units a timer runs every 15-20 seconds. For each run systemd logs three
  # info lines of its own (Starting, Finished, Deactivated successfully) on top
  # of whatever the unit prints: about 60K journal entries a day per server.
  # LogLevelMax filters PID 1's messages about the unit as well as the unit's
  # own output, so the output is raised to notice first, which keeps it and
  # drops only the per-run chatter.
  PERIODIC_UNITS = %w[postgres-metrics.service io-throttle@.service disk-full-check@.service].freeze

  PERIODIC_UNIT_DROPIN = <<~DROPIN
    [Service]
    SyslogLevel=notice
    LogLevelMax=notice
  DROPIN

  def quiet_periodic_units
    changed = false
    PERIODIC_UNITS.each do |unit|
      path = "/etc/systemd/system/#{unit}.d/50-quiet-journal.conf"
      next if File.exist?(path) && File.read(path) == PERIODIC_UNIT_DROPIN
      r "mkdir", "-p", File.dirname(path)
      safe_write_to_file(path, PERIODIC_UNIT_DROPIN)
      changed = true
    end
    r "systemctl", "daemon-reload" if changed
  end

  GUARDDUTY_UNIT = "amazon-guardduty-agent.service"

  # The image carries the GuardDuty agent for AWS runtime monitoring. Anywhere
  # else it cannot reach its endpoint, exits, and systemd restarts it every few
  # seconds: five journal lines per attempt, about 100K a day. Masking keeps a
  # package upgrade from enabling it again.
  def disable_guardduty
    return if r("systemctl", "show", "-p", "FragmentPath", "--value", GUARDDUTY_UNIT).strip.empty?
    return if r("systemctl", "is-enabled", GUARDDUTY_UNIT, expect: [0, 1]).strip == "masked"
    r "systemctl", "disable", "--now", GUARDDUTY_UNIT
    r "systemctl", "mask", GUARDDUTY_UNIT
  end

  APT = %w[env DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=600].freeze

  SNAPD_PIN_PATH = "/etc/apt/preferences.d/nosnap.pref"
  SNAPD_PIN = <<~PIN
    Package: snapd
    Pin: release a=*
    Pin-Priority: -10
  PIN

  # jammy's cloud image ships snapd with the lxd, core20 and core22 snaps:
  # 0.7-0.8 G of squashfs on the root disk, refreshed in the background, with
  # the previous revision of each kept after a refresh. Nothing on a Postgres
  # server uses them. --purge skips the snapshot snapd otherwise takes of a
  # removed snap, which would land in /var/lib/snapd/snapshots. Apps depend on
  # bases and bases on the snapd snap, so they go in that order.
  def purge_snapd
    if File.exist?("/usr/bin/snap")
      snaps = r("snap", "list").lines.drop(1).map { |line| line.split.values_at(0, 5) }
      snaps.sort_by { |name, notes| [snap_removal_rank(name, notes), name] }.each do |name, _|
        r "snap", "remove", "--purge", name
      end
      r(*APT, "purge", "snapd")
    end
    FileUtils.rm_rf(["/var/lib/snapd", "/snap", "/root/snap"])
    return if File.exist?(SNAPD_PIN_PATH) && File.read(SNAPD_PIN_PATH) == SNAPD_PIN
    safe_write_to_file(SNAPD_PIN_PATH, SNAPD_PIN)
  end

  def snap_removal_rank(name, notes)
    if name == "snapd"
      2
    elsif notes.to_s.include?("base")
      1
    else
      0
    end
  end

  KERNEL_VERSION_RE = /\d+\.\d+\.\d+-\d+/

  # The unversioned flavour metapackages: linux-virtual, linux-image-virtual,
  # linux-headers-generic, linux-azure-6.5 and so on. Named flavours only, so
  # linux-base, linux-firmware, linux-libc-dev and linux-tools-common stay.
  KERNEL_META_RE = /\Alinux-(?:image-|headers-|tools-|cloud-tools-|modules-extra-)?(?:generic|virtual|aws|azure|gcp|gke|oracle|kvm|lowlatency)/

  # The image installs its kernel next to the stock one, and unattended-upgrades
  # keeps the stock one current through the linux-image-virtual metapackage, so
  # 0.5-0.9 G of modules, headers, tools and initrds sit on the root disk for
  # kernels that have never booted here. Only the running kernel's packages
  # stay. The metapackages go by name: asked to remove only the versioned
  # packages, apt keeps a metapackage by upgrading it when a newer one is
  # known, which installs another kernel instead of removing one. The dry run
  # is the guard against that: nothing may be installed.
  def purge_stale_kernels
    running = r("uname", "-r").strip[KERNEL_VERSION_RE]
    return unless running

    installed = r("dpkg-query", "-W", "-f=${Package} ${Status}\n", "linux-*").lines.filter_map do |line|
      package, status = line.split(" ", 2)
      package if status&.strip == "install ok installed"
    end
    return unless installed.any? { |package| package.start_with?("linux-image-") && package.include?(running) }

    stale = installed.select do |package|
      if (version = package[KERNEL_VERSION_RE])
        version != running
      else
        package.match?(KERNEL_META_RE)
      end
    end
    return if stale.empty?

    planned = r(*APT, "-s", "purge", *stale)
    if (install = planned.lines.grep(/\AInst /)).any?
      fail "apt would install #{install.map { |line| line.split[1] }.join(", ")} while purging stale kernels; refusing"
    end

    r(*APT, "purge", *stale)
    r(*APT, "autoremove", "--purge")
  end

  # The image build leaves the apt archive cache populated, and the ParadeDB
  # package cache outlived the extensions (postgres-vm-images a42c000); nothing
  # in the rhizome reads it.
  def clean_package_caches
    r "apt-get", "clean"
    FileUtils.rm_rf("/var/cache/paradedb")
  end

  def configure_service_slice
    safe_write_to_file("/etc/systemd/system/system-go_services.slice", <<~SLICE)
      [Slice]
      MemoryHigh=2G
      MemoryMax=2560M
    SLICE
    GO_SERVICES.each do |svc, gomemlimit|
      r "mkdir", "-p", "/etc/systemd/system/#{svc}.service.d"
      safe_write_to_file("/etc/systemd/system/#{svc}.service.d/override.conf", <<~OVERRIDE)
        [Service]
        Slice=system-go_services.slice
        Environment=GOMEMLIMIT=#{gomemlimit}
      OVERRIDE
    end
    r "systemctl daemon-reload"
    # Apply cap so without restarting. Slice= and GOMEMLIMIT are load-time directives,
    # so only restart services not yet in slice.
    r "systemctl set-property system-go_services.slice MemoryHigh=2G MemoryMax=2560M"
    GO_SERVICES.each_key do |svc|
      current_slice = r("systemctl", "show", "#{svc}.service", "-p", "Slice", "--value").strip
      next if current_slice == "system-go_services.slice"
      r "systemctl", "try-restart", "#{svc}.service"
    end
  end

  def setup_data_directory
    r "chown postgres /dat"

    # Below commands are required for idempotency
    r "rm", "-rf", "/dat/#{@version}"
    r "rm", "-rf", "/etc/postgresql/#{@version}"

    r "echo :line | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf", line: "data_directory = '/dat/#{@version}/data'"

    # Install to path postgres can access
    r "install", "-m", "0755", File.expand_path("../bin/disk-full-check", __dir__), "/usr/local/sbin/disk-full-check"

    # Stage pg_log_throttle conf outside conf.d/ so PG does not load it
    # until disk-full-check symlinks it in at the restart threshold.
    r "install", "-d", "-m", "0755", "/etc/postgresql-common/pg-logs-throttle"
    r "install", "-m", "0644", File.expand_path("../lib/pg-logs-throttle/991-pg-logs-throttle.conf", __dir__), "/etc/postgresql-common/pg-logs-throttle/991-pg-logs-throttle.conf"

    safe_write_to_file("/etc/systemd/system/disk-full-check@.service", <<~DISKFULL)
      [Unit]
      Wants=disk-full-check@%i.timer
      Description=Mitigate disk full scenarios

      [Service]
      Type=oneshot
      User=postgres
      ExecStart=/usr/local/sbin/disk-full-check %i

      [Install]
      WantedBy=multi-user.target
    DISKFULL

    safe_write_to_file("/etc/systemd/system/disk-full-check@.timer", <<~DISKFULL)
      [Unit]
      Description=Schedule disk full check

      [Timer]
      OnBootSec=30s
      OnUnitActiveSec=20s
      AccuracySec=1s
      Unit=disk-full-check@%i.service

      [Install]
      WantedBy=timers.target
    DISKFULL

    r "sudo systemctl daemon-reload"
    r "sudo", "systemctl", "enable", "--now", "disk-full-check@#{@version}.timer"
  end

  def create_cluster
    # Use builtin collation for PG 17+
    if @version.to_i >= 17
      r "pg_createcluster", @version.to_s, "main", "--port=5432", "--", "--locale-provider=builtin", "--builtin-locale=C.UTF-8"
    else
      r "pg_createcluster", @version.to_s, "main", "--port=5432", "--locale=C.UTF8"
    end
  end
end
