# frozen_string_literal: true

require_relative "../lib/postgres_setup"

RSpec.describe PostgresSetup do
  let(:pg_setup) { described_class.new("17") }

  before do
    allow(pg_setup).to receive(:r)
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
end
