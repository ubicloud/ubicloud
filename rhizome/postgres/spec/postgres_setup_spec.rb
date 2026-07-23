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
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: true)
    end

    it "caps the reserve at 8 GiB on large VMs" do
      # 256 GB = 268435456 KB -> non_hugepage = 201326592 KB; cap branch wins:
      # 201326592 - 8 * 1048576 = 192937984 (vs 0.8 branch: 163158426)
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal:        268435456 kB\n")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=192937984\n")
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: true)
    end

    it "removes overcommit config when strict is false" do
      expect(pg_setup).to receive(:r).with("sudo rm -f /etc/sysctl.d/99-overcommit.conf")
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: false)
    end

    it "defaults to non-strict" do
      expect(pg_setup).to receive(:r).with("sudo rm -f /etc/sysctl.d/99-overcommit.conf")
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
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
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
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
      expect(pg_setup).to receive(:r).with("sudo install-postgresql-packages 17")
      pg_setup.install_packages
    end

    it "does nothing when the cache directory does not exist" do
      expect(File).to receive(:exist?).with("/var/cache/postgresql-packages/17").and_return(false)
      expect(pg_setup).not_to receive(:r)
      pg_setup.install_packages
    end
  end

  describe "#setup_data_directory" do
    it "sets up data directory with correct structure" do
      expect(pg_setup).to receive(:r).with("chown postgres /dat")
      expect(pg_setup).to receive(:r).with("rm -rf /dat/17")
      expect(pg_setup).to receive(:r).with("rm -rf /etc/postgresql/17")
      expect(pg_setup).to receive(:r).with("echo \"data_directory = '/dat/17/data'\" | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf")
      expect(pg_setup).to receive(:r).with("install -m 0755 #{File.expand_path("../bin/disk-full-check", __dir__).shellescape} /usr/local/sbin/disk-full-check")
      expect(pg_setup).to receive(:r).with("install -d -m 0755 /etc/postgresql-common/pg-logs-throttle")
      expect(pg_setup).to receive(:r).with("install -m 0644 #{File.expand_path("../lib/pg-logs-throttle/991-pg-logs-throttle.conf", __dir__).shellescape} /etc/postgresql-common/pg-logs-throttle/991-pg-logs-throttle.conf")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/disk-full-check@.service", satisfy { |s| s.include?("disk-full-check") })
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/disk-full-check@.timer", satisfy { |s| s.include?("OnBootSec=30s") })
      expect(pg_setup).to receive(:r).with("sudo systemctl daemon-reload")
      expect(pg_setup).to receive(:r).with("sudo systemctl enable --now disk-full-check@17.timer")
      pg_setup.setup_data_directory
    end
  end

  describe "#create_cluster" do
    it "creates a postgres cluster" do
      expect(pg_setup).to receive(:r).with("pg_createcluster 17 main --port=5432 --locale=C.UTF8")
      pg_setup.create_cluster
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
        expect(pg_setup).to receive(:r).with("mkdir -p /etc/systemd/system/#{svc}.service.d")
        expect(pg_setup).to receive(:safe_write_to_file).with("/etc/systemd/system/#{svc}.service.d/override.conf", <<~OVERRIDE)
          [Service]
          Slice=system-go_services.slice
          Environment=GOMEMLIMIT=#{lim}
        OVERRIDE
      end
      expect(pg_setup).to receive(:r).with("systemctl daemon-reload")
      expect(pg_setup).to receive(:r).with("systemctl set-property system-go_services.slice MemoryHigh=2G MemoryMax=2560M")

      # First two services already in system-go_services.slice -> skip restart.
      # Last two still in system.slice / missing -> try-restart.
      slices = ["system-go_services.slice", "system-go_services.slice", "system.slice", ""]
      PostgresSetup::GO_SERVICES.each_key.with_index do |svc, i|
        expect(pg_setup).to receive(:r).with("systemctl show #{svc}.service -p Slice --value").and_return("#{slices[i]}\n")
        if slices[i] != "system-go_services.slice"
          expect(pg_setup).to receive(:r).with("systemctl try-restart #{svc}.service")
        end
      end

      pg_setup.configure_service_slice
    end
  end
end
