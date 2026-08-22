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

  describe "#wal_mounted?" do
    it "reports whether /wal is a mountpoint" do
      expect(File).to receive(:foreach).with("/proc/mounts").and_return(["/dev/nvme1n1p1 /wal ext4 rw 0 0\n"].each)
      expect(pg_setup.wal_mounted?).to be true
      expect(File).to receive(:foreach).with("/proc/mounts").and_return(["/dev/bcache0 /dat ext4 rw 0 0\n"].each)
      expect(pg_setup.wal_mounted?).to be false
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
    [false, true].each do |wal|
      it "sets up data directory with correct structure (wal mounted: #{wal})" do
        expect(pg_setup).to receive(:wal_mounted?).and_return(wal)
        expect(pg_setup).to receive(:_run_command).with("chown postgres /dat")
        expect(pg_setup).to receive(:_run_command).with("rm", "-rf", "/dat/17")
        expect(pg_setup).to receive(:_run_command).with("rm", "-rf", "/etc/postgresql/17")
        if wal
          expect(pg_setup).to receive(:_run_command).with("rm", "-rf", "/wal/17")
          expect(pg_setup).to receive(:_run_command).with("install", "-d", "-o", "postgres", "/wal/17")
        end
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
  end

  describe "#create_cluster" do
    builtin = ["--", "--locale-provider=builtin", "--builtin-locale=C.UTF-8"]

    it "creates a postgres cluster with the builtin C.UTF-8 provider" do
      expect(pg_setup).to receive(:wal_mounted?).and_return(false)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "17", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "uses the builtin provider on 18" do
      pg_setup = described_class.new("18")
      expect(pg_setup).to receive(:wal_mounted?).and_return(false)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "18", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "handles the integer version passed by the upgrade path" do
      pg_setup = described_class.new(18)
      expect(pg_setup).to receive(:wal_mounted?).and_return(false)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "18", "main", "--port=5432", *builtin)
      pg_setup.create_cluster
    end

    it "keeps the libc provider on 16, which has no builtin provider" do
      pg_setup = described_class.new("16")
      expect(pg_setup).to receive(:wal_mounted?).and_return(false)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "16", "main", "--port=5432", "--locale=C.UTF8")
      pg_setup.create_cluster
    end

    it "puts pg_wal under /wal when mounted, after the initdb separator" do
      expect(pg_setup).to receive(:wal_mounted?).and_return(true)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "17", "main", "--port=5432", *builtin, "--waldir=/wal/17/pg_wal")
      pg_setup.create_cluster
    end

    it "adds the initdb separator for the waldir on 16" do
      pg_setup = described_class.new("16")
      expect(pg_setup).to receive(:wal_mounted?).and_return(true)
      expect(pg_setup).to receive(:_run_command).with("pg_createcluster", "16", "main", "--port=5432", "--locale=C.UTF8", "--", "--waldir=/wal/16/pg_wal")
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
        SystemMaxUse=4G
        Compress=yes
        ForwardToSyslog=no
      JOURNALD
      expect(pg_setup).to receive(:_run_command).with("systemctl", "restart", "systemd-journald")
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
