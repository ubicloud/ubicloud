# frozen_string_literal: true

require_relative "../lib/hugepages_setup"

RSpec.describe HugepagesSetup do
  let(:hugepages_setup) { described_class.new("17-main") }

  describe "#setup_postgres_hugepages" do
    it "calculates hugepages and updates postgres config" do
      expect(hugepages_setup).to receive(:get_postgres_param).with("shared_memory_size").at_least(:once).and_return("1076", "1130")
      expect(hugepages_setup).to receive(:shared_buffers_kib).and_return(1024 * 1024)
      expect(hugepages_setup).to receive(:hugepages_count).and_return(538)
      expect(hugepages_setup).to receive(:hugepage_size_kib).and_return(2048.0)
      expect(hugepages_setup).to receive(:update_postgres_hugepages_conf).with(538 * 2048)
      expect(hugepages_setup).to receive(:update_postgres_hugepages_conf).with(1024 * 1024 - (1130 - 1076) * 1024)

      expect { hugepages_setup.setup_postgres_hugepages }.not_to raise_error
    end
  end

  describe "#setup" do
    it "sets up hugepages if postgres is not running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(false)
      expect(hugepages_setup).to receive(:stop_postgres_cluster)
      expect(hugepages_setup).to receive(:setup_postgres_hugepages)
      expect(hugepages_setup).to receive(:setup_system_hugepages)
      expect { hugepages_setup.setup }.not_to raise_error
    end

    it "does not set up hugepages if postgres is running" do
      expect(hugepages_setup).to receive(:postgres_running?).and_return(true)
      expect(hugepages_setup).not_to receive(:stop_postgres_cluster)
      expect { hugepages_setup.setup }.not_to raise_error
    end
  end
end
