# frozen_string_literal: true

RSpec.describe Option do
  it "can load io_limits to struct" do
    expect(YAML).to receive(:load_file).with("config/vm_sizes.yml").and_return([
      {"name" => "no-io-limits", "io_limits" => [nil, nil, nil]},
      {"name" => "with-io-limits", "io_limits" => [1, 2, 2]}
    ])
    described_class::VmSizes.find { _1.name == "no-io-limits" }.tap do |option|
      expect(option.io_limits).to eq(described_class.NO_IO_LIMITS)
    end
    described_class::VmSizes.find { _1.name == "with-io-limits" }.tap do |option|
      expect(option.io_limits.max_ios_per_sec).to eq(1)
      expect(option.io_limits.max_read_mbytes_per_sec).to eq(2)
      expect(option.io_limits.max_write_mbytes_per_sec).to eq(3)
    end
  end
end
