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
      # 8 GB = 8388608 KB -> kbytes = 8388608 * 0.8 + 2 * 1048576 = 8808038
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal:        8388608 kB\n")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=8808038\n")
      expect(pg_setup).to receive(:r).with("sudo sysctl --system")
      pg_setup.configure_memory_overcommit(strict: true)
    end

    it "calculates correct kbytes for smaller memory" do
      # 4 GB = 4194304 KB -> kbytes = 4194304 * 0.8 + 2 * 1048576 = 5452595
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal:        4194304 kB\n")
      expect(pg_setup).to receive(:safe_write_to_file).with("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=5452595\n")
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
end
