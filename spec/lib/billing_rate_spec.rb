# frozen_string_literal: true

RSpec.describe BillingRate do
  it "each rate has a unique ID" do
    expect(described_class.rates.map { it["id"] }.size).to eq(described_class.rates.map { it["id"] }.uniq.size)
  end

  describe "#unit_price_from_resource_properties" do
    it "returns unit price for VmVCpu" do
      expect(described_class.unit_price_from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")).to be_a(Float)
    end

    it "returns nil for unknown type" do
      expect(described_class.unit_price_from_resource_properties("VmVCpu", "unknown", "hetzner-fsn1")).to be_nil
    end
  end

  describe ".postgres_storage_rate" do
    it "prefers the family's own storage row in every GCP location" do
      %w[gcp-us-central1 gcp-us-east4 gcp-europe-west1 gcp-europe-west3].product(%w[n2d-standard n2d-highmem], %w[PostgresStorage PostgresStandbyStorage]).each do |name, family, type|
        rate = described_class.postgres_storage_rate(type, family, Location[name:])
        expect(rate["resource_family"]).to eq("standard-#{family}")
        expect(rate["unit_price"]).to be > 0
      end
    end

    it "falls back to the flavor row for families priced with storage included" do
      location = Location[name: "gcp-us-central1"]
      expect(described_class.postgres_storage_rate("PostgresStorage", "c4a-standard", location)["resource_family"]).to eq("standard")
      expect(described_class.postgres_storage_rate("PostgresStandbyStorage", "standard", Location[Location::HETZNER_FSN1_ID])["resource_family"]).to eq("standard")
    end
  end

  describe ".line_item_description" do
    it "returns for VmVCpu" do
      expect(described_class.line_item_description("VmVCpu", "standard", 8)).to eq("standard-8 Virtual Machine")
    end

    it "returns for gpu" do
      expect(described_class.line_item_description("Gpu", "20b5", 2)).to eq("2x NVIDIA A100 80GB PCIe")
    end

    it "returns for IPAddress" do
      expect(described_class.line_item_description("IPAddress", "IPv4", 1)).to eq("IPv4 Address")
    end

    it "returns fractional GiB for MachineImageStorage" do
      expect(described_class.line_item_description("MachineImageStorage", "standard", 0.488)).to eq("0.49 GiB Storage for Machine Image")
      expect(described_class.line_item_description("MachineImageStorage", "standard", 2.7)).to eq("2.70 GiB Storage for Machine Image")
    end

    it "raises exception for unknown type" do
      expect { described_class.line_item_description("NewType", "NewFamily", 1) }.to raise_error("BUG: Unknown resource type for line item description")
    end

    it "each resource type has a description" do
      described_class.rates.each do |rate|
        expect(described_class.line_item_description(rate["resource_type"], rate["resource_family"], 1)).not_to be_nil
      end
    end
  end

  describe ".line_item_usage" do
    it "returns usage by duration" do
      expect(described_class.line_item_usage("VmVCpu", "standard", 5, 1)).to eq("1 minutes")
    end

    it "returns usage by amount" do
      expect(described_class.line_item_usage("GitHubRunnerMinutes", "standard-2", 5, 1)).to eq("5 minutes")
    end

    it "returns usage by token" do
      expect(described_class.line_item_usage("InferenceTokens", "test-model", 10, 1)).to eq("10 tokens")
    end

    it "returns usage by duration for gpu" do
      expect(described_class.line_item_usage("gpu", "20b5", 10, 2)).to eq("2 minutes")
    end
  end

  it "can unambiguously find active rate" do
    expect(described_class.rates.group_by { [it["resource_type"], it["resource_family"], it["location"], it["byoc"], it["active_from"]] }).not_to be_any { |k, v| v.count != 1 }
  end

  it "can find rate for aws locations" do
    project = Project.create(name: "test")

    loc = Location.create(
      name: "us-west-2",
      provider: "aws",
      ui_name: "aws-us-west-2",
      display_name: "aws-us-west-2",
      visible: false,
      project_id: project.id,
      byoc: true,
    )

    LocationCredentialAws.create(
      access_key: "test",
      secret_key: "test",
    ) { it.id = loc.id }

    expect(described_class.from_resource_properties("VmVCpu", "i8g", loc.name, loc.byoc, Time.now)).not_to be_nil
    expect(described_class.from_resource_properties("PostgresVCpu", "standard-i8g", loc.name, loc.byoc, Time.now)).not_to be_nil
  end
end
