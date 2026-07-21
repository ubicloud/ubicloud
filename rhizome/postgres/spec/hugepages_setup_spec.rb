# frozen_string_literal: true

require_relative "../lib/hugepages_setup"

RSpec.describe HugepagesSetup do
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }
  let(:hugepages_setup) { described_class.new("17-main", logger) }

  describe "#setup_postgres_hugepages" do
    it "calculates hugepages via overhead subtraction and rounding" do
      # Mock hugepage info: 512 x 2MB hugepages = 1024MB total hugepage space
      expect(hugepages_setup).to receive(:hugepage_info).and_return([512, 2048])

      # shared_memory_size increases due to simulated overhead:
      # 1024MB -> 1061MB (37MB overhead)
      expect(hugepages_setup).to receive(:get_postgres_param)
        .with("shared_memory_size").and_return(1061)

      # Block size for rounding shared_buffers
      expect(hugepages_setup).to receive(:get_postgres_param)
        .with("block_size").and_return(8192)  # 8KB blocks

      # First call: set shared_buffers to total hugepage space
      # (1024MB = 1,048,576 KiB)
      expect(hugepages_setup).to receive(:update_postgres_hugepages_conf)
        .with(1_048_576)

      # Second call: back off by overhead and round down to block boundary
      # overhead = (1061 - 1024) * 1024 = 37,888 KiB
      # target = 1,048,576 - 37,888 = 1,010,688 KiB
      expected_shared_buffers = 1_010_688
      expect(hugepages_setup).to receive(:update_postgres_hugepages_conf)
        .with(expected_shared_buffers)
      expect(expected_shared_buffers & 0b111).to eq(0)  # Divisible by 8

      expect { hugepages_setup.setup_postgres_hugepages }.not_to raise_error
    end

    it "skips setup if no hugepages are configured" do
      expect(hugepages_setup).to receive(:hugepage_info).and_return([0, 2048])
      expect(hugepages_setup).not_to receive(:get_postgres_param)
      expect(hugepages_setup).not_to receive(:update_postgres_hugepages_conf)
      expect(logger).to receive(:warn).with("No hugepages configured, skipping setup.")
      expect { hugepages_setup.setup_postgres_hugepages }.not_to raise_error
    end
  end

  describe "#hugepage_info" do
    it "parses hugepage count and size from /proc/meminfo" do
      meminfo = "HugePages_Total:     512\nHugepagesize:       2048 kB\n"
      expect(File).to receive(:read).with("/proc/meminfo").and_return(meminfo)
      count, size = hugepages_setup.hugepage_info
      expect(count).to eq(512)
      expect(size).to eq(2048)
    end
  end

  describe "#get_postgres_param" do
    it "returns the integer value of a postgres parameter" do
      expect(hugepages_setup).to receive(:_run_command).with(
        "sudo", "-u", "postgres", "/usr/lib/postgresql/17/bin/postgres", "-D", "/dat/17/data", "-c", "config_file=/etc/postgresql/17/main/postgresql.conf", "-C", "shared_buffers",
      ).and_return("131072\n")
      expect(hugepages_setup.get_postgres_param("shared_buffers")).to eq(131072)
    end
  end

  describe "#stop_postgres_cluster" do
    it "stops the postgres cluster (exit 0 or 2)" do
      expect(hugepages_setup).to receive(:_run_command).with("sudo", "pg_ctlcluster", "stop", "17", "main", expect: [0, 2])
      hugepages_setup.stop_postgres_cluster
    end
  end

  describe "#update_postgres_hugepages_conf" do
    it "writes the hugepages configuration file" do
      expect(hugepages_setup).to receive(:safe_write_to_file).with(
        "/etc/postgresql/17/main/conf.d/002-hugepages.conf",
        satisfy { |s| s.include?("huge_pages = 'on'") && s.include?("524288kB") },
      )
      hugepages_setup.update_postgres_hugepages_conf(524288)
    end
  end

  describe "#postgres_running?" do
    it "returns false when postgres is not running (exit 3)" do
      expect(hugepages_setup).to receive(:_run_command).with("sudo", "pg_ctlcluster", "status", "17", "main", expect: [3]).and_return("")
      expect(hugepages_setup.postgres_running?).to be false
    end

    it "returns true when postgres is running (r raises CommandFail)" do
      expect(hugepages_setup).to receive(:_run_command).with("sudo", "pg_ctlcluster", "status", "17", "main", expect: [3]).and_raise(CommandFail.new("error", "", ""))
      expect(hugepages_setup.postgres_running?).to be true
    end
  end

  describe "#setup" do
    it "stops postgres and runs hugepages setup when postgres is not running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(false)
      expect(hugepages_setup).to receive(:stop_postgres_cluster)
      expect(hugepages_setup).to receive(:setup_postgres_hugepages)
      hugepages_setup.setup
    end

    it "does nothing when postgres is already running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(true)
      expect(hugepages_setup).not_to receive(:stop_postgres_cluster)
      expect(hugepages_setup).not_to receive(:setup_postgres_hugepages)
      hugepages_setup.setup
    end
  end
end
