# frozen_string_literal: true

require_relative "../lib/postgres_setup"

RSpec.describe PostgresSetup do
  let(:pg_setup) { described_class.new("17") }

  before do
    allow(pg_setup).to receive(:safe_write_to_file)
  end

  describe "#configure_memory_overcommit" do
    it "sets strict overcommit settings when strict is true" do
      # 8 GB = 8388608 KB -> kbytes = 8388608 * 0.75 * 0.8 + 2 * 1048576 = 7130317
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal:        8388608 kB\n")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=7130317\n")
      expect(pg_setup).to receive(:_run_command).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: true)
    end

    it "removes overcommit config when strict is false" do
      expect(pg_setup).to receive(:_run_command).with("sudo rm -f /etc/sysctl.d/99-overcommit.conf")
      expect(pg_setup).to receive(:_run_command).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: false)
    end

    it "defaults to non-strict" do
      expect(pg_setup).to receive(:_run_command).with("sudo rm -f /etc/sysctl.d/99-overcommit.conf")
      expect(pg_setup).to receive(:_run_command).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit
    end
  end

  describe "#configure_tcp_keepalive" do
    it "writes sysctl drop-in for 3 probes at 20s interval" do
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/sysctl.d/99-tcp-keepalive.conf", <<~SYSCTL)
        net.ipv4.tcp_keepalive_time=30
        net.ipv4.tcp_keepalive_probes=3
        net.ipv4.tcp_keepalive_intvl=10
      SYSCTL
      expect(pg_setup).to receive(:_run_command).with("sudo sysctl --system")
      pg_setup.configure_tcp_keepalive
    end
  end

  describe "GO_SERVICES" do
    it "sum of GOMEMLIMIT values stays within the slice MemoryHigh" do
      to_bytes = ->(s) {
        m = s.match(/\A(\d+)(MiB|GiB)\z/) or raise "unrecognized unit in #{s}"
        Integer(m[1], 10) * ((m[2] == "GiB") ? 1024**3 : 1024**2)
      }
      expect(to_bytes.call("1GiB")).to eq(1024**3)
      sum = PostgresSetup::GO_SERVICES.values.sum(&to_bytes)
      expect(sum).to be <= 2 * 1024**3 # MemoryHigh=2G on system-go_services.slice
    end
  end

  describe "#install_packages" do
    it "installs packages when the cache directory exists" do
      expect(File).to receive(:exist?).with("/var/cache/postgresql-packages/17").and_return(true)
      expect(pg_setup).to receive(:_run_command).with("sudo", "install-postgresql-packages", "17")
      pg_setup.install_packages
    end

    it "does nothing when the cache directory does not exist" do
      expect(File).to receive(:exist?).with("/var/cache/postgresql-packages/17").and_return(false)
      expect(pg_setup).not_to receive(:_run_command)
      pg_setup.install_packages
    end
  end

  describe "#setup_data_directory" do
    it "sets up data directory with correct structure" do
      expect(pg_setup).to receive(:_run_command).with("chown postgres /dat")
      expect(pg_setup).to receive(:_run_command).with("rm", "-rf", "/dat/17")
      expect(pg_setup).to receive(:_run_command).with("rm", "-rf", "/etc/postgresql/17")
      expect(pg_setup).to receive(:_run_command).with("echo data_directory\\ \\=\\ \\'/dat/17/data\\' | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf")
      expect(pg_setup).to receive(:_run_command).with("install", "-m", "0755", File.expand_path("../bin/disk-full-check", __dir__), "/usr/local/sbin/disk-full-check")
      expect(pg_setup).to receive(:_run_command).with("install", "-d", "-m", "0755", "/etc/postgresql-common/pg-logs-throttle")
      expect(pg_setup).to receive(:_run_command).with("install", "-m", "0644", File.expand_path("../lib/pg-logs-throttle/991-pg-logs-throttle.conf", __dir__), "/etc/postgresql-common/pg-logs-throttle/991-pg-logs-throttle.conf")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/disk-full-check@.service", satisfy { |s| s.include?("disk-full-check") })
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/disk-full-check@.timer", satisfy { |s| s.include?("OnBootSec=30s") })
      expect(pg_setup).to receive(:_run_command).with("sudo systemctl daemon-reload")
      expect(pg_setup).to receive(:_run_command).with("sudo", "systemctl", "enable", "--now", "disk-full-check@17.timer")
      pg_setup.setup_data_directory
    end
  end

  describe "#create_cluster" do
    builtin = ["--", "--locale-provider=builtin", "--builtin-locale=C.UTF-8"]

    it "creates a postgres cluster with the builtin C.UTF-8 provider" do
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "17", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "uses the builtin provider on 18" do
      pg_setup = described_class.new("18")
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "18", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "handles the integer version passed by the upgrade path" do
      pg_setup = described_class.new(18)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "18", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "keeps the libc provider on 16, which has no builtin provider" do
      pg_setup = described_class.new("16")
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "16", "main", "--port=5432", "--locale=C.UTF8")
      pg_setup.create_cluster
    end
  end

  describe "#configure_journald" do
    it "writes the drop-in, restarts journald, purges rsyslog and reclaims what it wrote" do
      expect(File).to receive(:exist?).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(false)
      expect(pg_setup).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/journald.conf.d")
      expect(pg_setup).to receive(:safe_write_to_file).with(PostgresSetup::JOURNALD_CONF_PATH, <<~JOURNALD)
        [Journal]
        Storage=persistent
        SystemMaxUse=1G
        SystemMaxFileSize=64M
        MaxRetentionSec=1month
        SplitMode=none
        Compress=yes
        ForwardToSyslog=no
      JOURNALD
      expect(pg_setup).to receive(:_run_command).with("systemctl", "restart", "systemd-journald")
      expect(pg_setup).to receive(:_run_command).with("journalctl", "--rotate")
      expect(pg_setup).to receive(:_run_command).with("journalctl", "--vacuum-size=1G")
      expect(File).to receive(:exist?).with("/usr/sbin/rsyslogd").and_return(true)
      expect(pg_setup).to receive(:_run_command).with("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "purge", "-y", "rsyslog")
      expect(Dir).to receive(:glob).with(PostgresSetup::RSYSLOG_LOGS_GLOB).and_return(["/var/log/syslog", "/var/log/syslog.1", "/var/log/auth.log.2.gz"])
      expect(FileUtils).to receive(:rm_f).with(["/var/log/syslog", "/var/log/syslog.1", "/var/log/auth.log.2.gz"])

      pg_setup.configure_journald
    end

    it "skips the write and the journald restart when the drop-in already matches" do
      expect(File).to receive(:exist?).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(true)
      expect(File).to receive(:read).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(PostgresSetup::JOURNALD_CONF)
      expect(pg_setup).not_to receive(:safe_write_to_file)
      expect(File).to receive(:exist?).with("/usr/sbin/rsyslogd").and_return(false)

      pg_setup.configure_journald
    end

    it "rewrites the drop-in when the content differs" do
      expect(File).to receive(:exist?).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(true)
      expect(File).to receive(:read).with(PostgresSetup::JOURNALD_CONF_PATH).and_return("[Journal]\nSystemMaxUse=1G\n")
      expect(pg_setup).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/journald.conf.d")
      expect(pg_setup).to receive(:safe_write_to_file).with(PostgresSetup::JOURNALD_CONF_PATH, PostgresSetup::JOURNALD_CONF)
      expect(pg_setup).to receive(:_run_command).with("systemctl", "restart", "systemd-journald")
      expect(pg_setup).to receive(:_run_command).with("journalctl", "--rotate")
      expect(pg_setup).to receive(:_run_command).with("journalctl", "--vacuum-size=1G")
      expect(File).to receive(:exist?).with("/usr/sbin/rsyslogd").and_return(false)

      pg_setup.configure_journald
    end

    it "leaves rsyslog alone on a server built from an image that has none" do
      expect(File).to receive(:exist?).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(true)
      expect(File).to receive(:read).with(PostgresSetup::JOURNALD_CONF_PATH).and_return(PostgresSetup::JOURNALD_CONF)
      expect(File).to receive(:exist?).with("/usr/sbin/rsyslogd").and_return(false)
      expect(Dir).not_to receive(:glob)
      expect(FileUtils).not_to receive(:rm_f)

      pg_setup.configure_journald
    end

    it "covers every file the stock rsyslog config writes" do
      stock_paths = [
        "/var/log/syslog", "/var/log/mail.info", "/var/log/mail.warn", "/var/log/mail.err",
        "/var/log/mail.log", "/var/log/daemon.log", "/var/log/kern.log", "/var/log/auth.log",
        "/var/log/user.log", "/var/log/lpr.log", "/var/log/cron.log", "/var/log/debug",
        "/var/log/messages",
      ]
      stock_paths.each do |path|
        expect(File.fnmatch?(PostgresSetup::RSYSLOG_LOGS_GLOB, path, File::FNM_EXTGLOB)).to be(true), "#{path} not covered"
        expect(File.fnmatch?(PostgresSetup::RSYSLOG_LOGS_GLOB, "#{path}.2.gz", File::FNM_EXTGLOB)).to be(true), "#{path}.2.gz not covered"
      end
    end

    it "does not match unrelated files under /var/log" do
      ["/var/log/postgresql.log", "/var/log/journal", "/var/log/wtmp", "/var/log/dpkg.log"].each do |path|
        expect(File.fnmatch?(PostgresSetup::RSYSLOG_LOGS_GLOB, path, File::FNM_EXTGLOB)).to be(false), "#{path} matched"
      end
    end
  end

  describe "#configure_root_disk" do
    it "runs every step, disabling GuardDuty off AWS" do
      expect(pg_setup).to receive(:quiet_periodic_units).ordered
      expect(pg_setup).to receive(:disable_guardduty).ordered
      expect(pg_setup).to receive(:purge_snapd).ordered
      expect(pg_setup).to receive(:purge_stale_kernels).ordered
      expect(pg_setup).to receive(:clean_package_caches).ordered
      pg_setup.configure_root_disk(aws: false)
    end

    it "leaves GuardDuty alone on AWS" do
      expect(pg_setup).to receive_messages(quiet_periodic_units: nil, purge_snapd: nil, purge_stale_kernels: nil, clean_package_caches: nil)
      expect(pg_setup).not_to receive(:disable_guardduty)
      pg_setup.configure_root_disk(aws: true)
    end

    it "leaves GuardDuty alone when the control plane did not say where the server runs" do
      expect(pg_setup).to receive_messages(quiet_periodic_units: nil, purge_snapd: nil, purge_stale_kernels: nil, clean_package_caches: nil)
      expect(pg_setup).not_to receive(:disable_guardduty)
      pg_setup.configure_root_disk(aws: nil)
    end
  end

  describe "#quiet_periodic_units" do
    let(:dropin) { PostgresSetup::PERIODIC_UNIT_DROPIN }
    let(:units) { PostgresSetup::PERIODIC_UNITS }

    def dropin_path(unit) = "/etc/systemd/system/#{unit}.d/50-quiet-journal.conf"

    it "raises the unit's own output to notice so LogLevelMax keeps it and drops only systemd's" do
      expect(dropin).to eq("[Service]\nSyslogLevel=notice\nLogLevelMax=notice\n")
      expect(units).to contain_exactly("postgres-metrics.service", "io-throttle@.service", "disk-full-check@.service")
    end

    it "writes a drop-in per unit and reloads systemd" do
      units.each do |unit|
        expect(File).to receive(:exist?).with(dropin_path(unit)).and_return(false)
        expect(pg_setup).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/system/#{unit}.d")
        expect(pg_setup).to receive(:safe_write_to_file).with(dropin_path(unit), dropin)
      end
      expect(pg_setup).to receive(:_run_command).with("systemctl", "daemon-reload")

      pg_setup.quiet_periodic_units
    end

    it "skips the reload when every drop-in already matches" do
      units.each do |unit|
        expect(File).to receive(:exist?).with(dropin_path(unit)).and_return(true)
        expect(File).to receive(:read).with(dropin_path(unit)).and_return(dropin)
      end
      expect(pg_setup).not_to receive(:safe_write_to_file)
      expect(pg_setup).not_to receive(:_run_command)

      pg_setup.quiet_periodic_units
    end

    it "rewrites a drop-in whose content differs" do
      units.each do |unit|
        expect(File).to receive(:exist?).with(dropin_path(unit)).and_return(true)
        expect(File).to receive(:read).with(dropin_path(unit)).and_return((unit == units.first) ? "[Service]\nLogLevelMax=info\n" : dropin)
      end
      expect(pg_setup).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/system/#{units.first}.d")
      expect(pg_setup).to receive(:safe_write_to_file).with(dropin_path(units.first), dropin)
      expect(pg_setup).to receive(:_run_command).with("systemctl", "daemon-reload")

      pg_setup.quiet_periodic_units
    end
  end

  describe "#disable_guardduty" do
    let(:unit) { PostgresSetup::GUARDDUTY_UNIT }
    let(:show) { ["systemctl", "show", "-p", "FragmentPath", "--value", unit] }

    it "stops, disables and masks the agent" do
      expect(pg_setup).to receive(:_run_command).with(*show).and_return("/lib/systemd/system/amazon-guardduty-agent.service\n")
      expect(pg_setup).to receive(:_run_command).with("systemctl", "is-enabled", unit, expect: [0, 1]).and_return("enabled\n")
      expect(pg_setup).to receive(:_run_command).with("systemctl", "disable", "--now", unit).ordered
      expect(pg_setup).to receive(:_run_command).with("systemctl", "mask", unit).ordered

      pg_setup.disable_guardduty
    end

    it "does nothing on an image without the agent" do
      expect(pg_setup).to receive(:_run_command).with(*show).and_return("\n")

      pg_setup.disable_guardduty
    end

    it "does nothing once masked" do
      expect(pg_setup).to receive(:_run_command).with(*show).and_return("/dev/null\n")
      expect(pg_setup).to receive(:_run_command).with("systemctl", "is-enabled", unit, expect: [0, 1]).and_return("masked\n")

      pg_setup.disable_guardduty
    end
  end

  describe "#purge_snapd" do
    let(:leftovers) { ["/var/lib/snapd", "/snap", "/root/snap"] }
    let(:snap_list) do
      <<~SNAPS
        Name    Version        Rev    Tracking       Publisher    Notes
        core22  20260410       2437   latest/stable  canonical**  base
        lxd     5.0.9-ea18dad  40575  5.0/stable/…   canonical**  -
        snapd   2.76.2         27710  latest/stable  canonical**  snapd
        core20  20260410       2866   latest/stable  canonical**  base
      SNAPS
    end

    it "removes apps, then bases, then snapd itself, purges the package, sweeps and pins it out" do
      expect(File).to receive(:exist?).with("/usr/bin/snap").and_return(true)
      expect(pg_setup).to receive(:_run_command).with("snap", "list").and_return(snap_list)
      %w[lxd core20 core22 snapd].each do |name|
        expect(pg_setup).to receive(:_run_command).with("snap", "remove", "--purge", name).ordered
      end
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "purge", "snapd").ordered
      expect(FileUtils).to receive(:rm_rf).with(leftovers)
      expect(File).to receive(:exist?).with(PostgresSetup::SNAPD_PIN_PATH).and_return(false)
      expect(pg_setup).to receive(:safe_write_to_file).with(PostgresSetup::SNAPD_PIN_PATH, PostgresSetup::SNAPD_PIN)

      pg_setup.purge_snapd
    end

    it "purges the package even when no snaps are installed" do
      expect(File).to receive(:exist?).with("/usr/bin/snap").and_return(true)
      expect(pg_setup).to receive(:_run_command).with("snap", "list").and_return("")
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "purge", "snapd")
      expect(FileUtils).to receive(:rm_rf).with(leftovers)
      expect(File).to receive(:exist?).with(PostgresSetup::SNAPD_PIN_PATH).and_return(false)
      expect(pg_setup).to receive(:safe_write_to_file).with(PostgresSetup::SNAPD_PIN_PATH, PostgresSetup::SNAPD_PIN)

      pg_setup.purge_snapd
    end

    it "only sweeps when snapd is already gone and the pin is in place" do
      expect(File).to receive(:exist?).with("/usr/bin/snap").and_return(false)
      expect(FileUtils).to receive(:rm_rf).with(leftovers)
      expect(File).to receive(:exist?).with(PostgresSetup::SNAPD_PIN_PATH).and_return(true)
      expect(File).to receive(:read).with(PostgresSetup::SNAPD_PIN_PATH).and_return(PostgresSetup::SNAPD_PIN)
      expect(pg_setup).not_to receive(:safe_write_to_file)

      pg_setup.purge_snapd
    end

    it "rewrites a pin whose content differs" do
      expect(File).to receive(:exist?).with("/usr/bin/snap").and_return(false)
      expect(FileUtils).to receive(:rm_rf).with(leftovers)
      expect(File).to receive(:exist?).with(PostgresSetup::SNAPD_PIN_PATH).and_return(true)
      expect(File).to receive(:read).with(PostgresSetup::SNAPD_PIN_PATH).and_return("Package: snapd\nPin-Priority: 100\n")
      expect(pg_setup).to receive(:safe_write_to_file).with(PostgresSetup::SNAPD_PIN_PATH, PostgresSetup::SNAPD_PIN)

      pg_setup.purge_snapd
    end

    it "pins snapd below anything apt would install" do
      expect(PostgresSetup::SNAPD_PIN).to eq("Package: snapd\nPin: release a=*\nPin-Priority: -10\n")
    end
  end

  describe "#purge_stale_kernels" do
    let(:dpkg_query) { ["dpkg-query", "-W", "-f=${Package} ${Status}\n", "linux-*"] }

    let(:dpkg_output) do
      <<~DPKG
        linux-azure-6.5 install ok installed
        linux-base install ok installed
        linux-base-sgx install ok installed
        linux-cloud-tools-common install ok installed
        linux-firmware install ok installed
        linux-headers-5.15.0-190 install ok installed
        linux-headers-5.15.0-190-generic install ok installed
        linux-headers-6.8.0-90-generic install ok installed
        linux-headers-generic install ok installed
        linux-headers-virtual install ok installed
        linux-hwe-6.8-headers-6.8.0-90 install ok installed
        linux-hwe-6.8-tools-6.8.0-90 install ok installed
        linux-image-5.15.0-190-generic install ok installed
        linux-image-6.5.0-1011-azure install ok installed
        linux-image-6.8.0-90-generic install ok installed
        linux-image-unsigned-5.15.0-187-generic unknown ok not-installed
        linux-image-virtual install ok installed
        linux-libc-dev install ok installed
        linux-modules-5.15.0-190-generic install ok installed
        linux-modules-extra-6.8.0-90-generic install ok installed
        linux-tools-6.8.0-90-generic install ok installed
        linux-tools-common install ok installed
        linux-virtual install ok installed

      DPKG
    end
    let(:stale) do
      %w[
        linux-azure-6.5 linux-headers-5.15.0-190 linux-headers-5.15.0-190-generic linux-headers-generic
        linux-headers-virtual linux-image-5.15.0-190-generic linux-image-6.5.0-1011-azure linux-image-virtual
        linux-modules-5.15.0-190-generic linux-virtual
      ]
    end

    it "purges other kernels' versioned packages and the flavour metapackages, then autoremoves" do
      expect(pg_setup).to receive(:_run_command).with("uname", "-r").and_return("6.8.0-90-generic\n")
      expect(pg_setup).to receive(:_run_command).with(*dpkg_query).and_return(dpkg_output)
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "-s", "purge", *stale).and_return(<<~PLAN).ordered
        Remv linux-virtual [5.15.0.190.169]
        Remv linux-image-5.15.0-190-generic [5.15.0-190.200]
        Purg linux-image-5.15.0-190-generic
      PLAN
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "purge", *stale).ordered
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "autoremove", "--purge").ordered

      pg_setup.purge_stale_kernels
    end

    it "refuses when apt would keep a metapackage by installing a newer kernel" do
      expect(pg_setup).to receive(:_run_command).with("uname", "-r").and_return("6.8.0-90-generic\n")
      expect(pg_setup).to receive(:_run_command).with(*dpkg_query).and_return(dpkg_output)
      expect(pg_setup).to receive(:_run_command).with(*PostgresSetup::APT, "-s", "purge", *stale).and_return(<<~PLAN)
        Inst linux-modules-5.15.0-164-generic (5.15.0-164.174 Ubuntu:22.04/jammy-updates [amd64])
        Inst linux-image-5.15.0-164-generic (5.15.0-164.174 Ubuntu:22.04/jammy-updates [amd64])
        Remv linux-image-5.15.0-190-generic [5.15.0-190.200]
      PLAN
      expect(pg_setup).not_to receive(:_run_command).with(*PostgresSetup::APT, "purge", any_args)

      expect { pg_setup.purge_stale_kernels }.to raise_error(RuntimeError, /would install linux-modules-5.15.0-164-generic, linux-image-5.15.0-164-generic/)
    end

    it "does nothing when only the running kernel is installed" do
      expect(pg_setup).to receive(:_run_command).with("uname", "-r").and_return("6.8.0-90-generic\n")
      expect(pg_setup).to receive(:_run_command).with(*dpkg_query).and_return(<<~DPKG)
        linux-base install ok installed
        linux-image-6.8.0-90-generic install ok installed
        linux-modules-6.8.0-90-generic install ok installed
        linux-tools-common install ok installed
      DPKG

      pg_setup.purge_stale_kernels
    end

    it "does nothing when the running kernel's image package is not installed" do
      expect(pg_setup).to receive(:_run_command).with("uname", "-r").and_return("6.8.0-90-generic\n")
      expect(pg_setup).to receive(:_run_command).with(*dpkg_query).and_return(<<~DPKG)
        linux-image-5.15.0-190-generic install ok installed
        linux-modules-5.15.0-190-generic install ok installed
      DPKG

      pg_setup.purge_stale_kernels
    end

    it "does nothing when the running kernel version cannot be parsed" do
      expect(pg_setup).to receive(:_run_command).with("uname", "-r").and_return("custom\n")

      pg_setup.purge_stale_kernels
    end
  end

  describe "#clean_package_caches" do
    it "empties the apt archive cache and removes the orphaned ParadeDB cache" do
      expect(pg_setup).to receive(:_run_command).with("apt-get", "clean")
      expect(FileUtils).to receive(:rm_rf).with("/var/cache/paradedb")

      pg_setup.clean_package_caches
    end
  end

  describe "#configure_service_slice" do
    it "writes slice + drop-ins, reloads, sets slice property, restarts only services not yet in the slice" do
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/system-go_services.slice", <<~SLICE)
        [Slice]
        MemoryHigh=2G
        MemoryMax=2560M
      SLICE
      PostgresSetup::GO_SERVICES.each do |svc, lim|
        expect(pg_setup).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/system/#{svc}.service.d")
        expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/#{svc}.service.d/override.conf", <<~OVERRIDE)
          [Service]
          Slice=system-go_services.slice
          Environment=GOMEMLIMIT=#{lim}
        OVERRIDE
      end
      expect(pg_setup).to receive(:_run_command).with("systemctl daemon-reload")
      expect(pg_setup).to receive(:_run_command).with("systemctl set-property system-go_services.slice MemoryHigh=2G MemoryMax=2560M")

      # First two services already in system-go_services.slice -> skip restart.
      # Last two still in system.slice / missing -> try-restart.
      slices = ["system-go_services.slice", "system-go_services.slice", "system.slice", ""]
      PostgresSetup::GO_SERVICES.each_key.with_index do |svc, i|
        expect(pg_setup).to receive(:_run_command).with("systemctl", "show", "#{svc}.service", "-p", "Slice", "--value").and_return("#{slices[i]}\n")
        if slices[i] != "system-go_services.slice"
          expect(pg_setup).to receive(:_run_command).with("systemctl", "try-restart", "#{svc}.service")
        end
      end

      pg_setup.configure_service_slice
    end
  end
end
