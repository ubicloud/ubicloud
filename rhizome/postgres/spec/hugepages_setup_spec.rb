# frozen_string_literal: true

require_relative "../lib/hugepages_setup"

RSpec.describe HugepagesSetup do
  let(:logger) { instance_double(Logger, warn: nil) }
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
end
