# frozen_string_literal: true

require_relative "../lib/hugepages_setup"

RSpec.describe HugepagesSetup do
  let(:hugepages_setup) { described_class.new("17-main") }

  describe "#hugepages_config" do
    it "calculates the correct hugepages configuration when shared_memory_size is a multiple of hugepage size" do
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_buffers").and_return("1538")
      expect(hugepages_setup).to receive(:get_postgres_param).with("block_size").and_return("8192")
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_memory_size").and_return("16")
      expect(hugepages_setup).to receive(:hugepage_size_kib).at_least(:once).and_return(2048)
      expect(hugepages_setup.hugepages_config).to eq(
        {
          hugepages_count: 8,
          shared_buffers_kib: 1538 * 8192 / 1024
        }
      )
    end

    it "calculates the correct hugepages configuration when the last page is less than half filled" do
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_buffers").and_return("1238")
      expect(hugepages_setup).to receive(:get_postgres_param).with("block_size").and_return("8192")
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_memory_size").and_return("14.5")
      expect(hugepages_setup).to receive(:hugepage_size_kib).at_least(:once).and_return(2048)
      expect(hugepages_setup.hugepages_config).to eq(
        {
          hugepages_count: 7,
          shared_buffers_kib: 1174 * 8192 / 1024
        }
      )
    end

    it "calculates the correct hugepages configuration when the last page is more than half filled" do
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_buffers").and_return("1238")
      expect(hugepages_setup).to receive(:get_postgres_param).with("block_size").and_return("8192")
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_memory_size").and_return("15.5")
      expect(hugepages_setup).to receive(:hugepage_size_kib).at_least(:once).and_return(2048)
      expect(hugepages_setup.hugepages_config).to eq(
        {
          hugepages_count: 8,
          shared_buffers_kib: 1302 * 8192 / 1024
        }
      )
    end
  end

  describe "#setup" do
    it "sets up hugepages if postgres is not running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(false)
      expect(hugepages_setup).to receive(:stop_postgres_cluster)
      expect(hugepages_setup).to receive(:hugepages_config).and_return({
        hugepages_count: 8,
        shared_buffers_kib: 14 * 1024 * 1024
      })
      expect(hugepages_setup).to receive(:setup_system_hugepages).with(8)
      expect(hugepages_setup).to receive(:setup_postgres_hugepages).with(14 * 1024 * 1024)
      expect { hugepages_setup.setup }.not_to raise_error
    end

    it "does not set up hugepages if postgres is running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(true)
      expect(hugepages_setup).not_to receive(:hugepages_config)
      expect { hugepages_setup.setup }.not_to raise_error
    end
  end
end
