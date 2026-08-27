# frozen_string_literal: true

RSpec.describe Validation::CsiConfigValidator do
  def errors_for(config)
    errors = Sequel::Model::Errors.new
    described_class.validate(config, errors)
    errors[:csi_config]
  end

  describe ".validate" do
    it "accepts every key at its default value" do
      expect(errors_for(described_class::DEFAULTS)).to be_nil
    end

    it "accepts an empty config" do
      expect(errors_for({})).to be_nil
    end

    it "rejects a key that is not in the schema" do
      expect(errors_for({"PATH" => "/bin"})).to eq ["PATH is not a known CSI configuration key"]
    end

    it "rejects a value that is not a string" do
      expect(errors_for({"DISK_LIMIT_GB" => 50})).to eq ["DISK_LIMIT_GB must be a string"]
    end

    it "accepts an integer value inside the allowed range" do
      expect(errors_for({"DISK_LIMIT_GB" => "50", "RESERVE_PERCENT" => "30"})).to be_nil
    end

    it "rejects a non integer value" do
      expect(errors_for({"DISK_LIMIT_GB" => "50GB"})).to eq ["DISK_LIMIT_GB must be an integer"]
    end

    it "rejects an integer value outside the allowed range" do
      expect(errors_for({"RESERVE_PERCENT" => "5"})).to eq ["RESERVE_PERCENT must be between 10 and 50"]
    end

    it "accepts an empty endpoint list" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => ""})).to be_nil
    end

    it "accepts several endpoints including an IPv6 address" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "example.com:443, 10.0.0.1:8080,2001:db8::1:5432"})).to be_nil
    end

    it "rejects an endpoint without a port" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "example.com"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "rejects an endpoint without a host" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => ":443"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "rejects an IPv6 address that is missing its port" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "2001:db8::1"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "rejects an endpoint with a non numeric port" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "example.com:https"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "rejects an endpoint with a port outside the valid range" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "example.com:0"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "example.com:65536"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "rejects a host that is not a valid hostname" do
      expect(errors_for({"EXTERNAL_ENDPOINTS" => "exa mple.com:443"})).to eq ["EXTERNAL_ENDPOINTS must be a comma separated list of host:port"]
    end

    it "reports an error for each invalid key" do
      expect(errors_for({"DISK_LIMIT_GB" => "5", "RESERVE_PERCENT" => "100"})).to eq ["DISK_LIMIT_GB must be between 10 and 300", "RESERVE_PERCENT must be between 10 and 50"]
    end
  end

  describe ".parse_endpoints" do
    it "returns the canonical form of the list" do
      expect(described_class.parse_endpoints(" example.com:0443 ,10.0.0.1:8080")).to eq "example.com:443,10.0.0.1:8080"
    end

    it "returns nil when an entry is not a host:port pair" do
      expect(described_class.parse_endpoints("example.com")).to be_nil
    end
  end

  describe ".workload" do
    it "returns the workload that reads the key" do
      expect(described_class.workload("EXTERNAL_ENDPOINTS")).to eq :nodeplugin
      expect(described_class.workload("DISK_LIMIT_GB")).to eq :provisioner
    end
  end
end
