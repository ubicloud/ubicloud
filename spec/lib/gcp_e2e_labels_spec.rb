# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GcpE2eLabels do
  around do |ex|
    original = ENV["E2E_RUN_ID"]
    ex.run
  ensure
    ENV["E2E_RUN_ID"] = original
  end

  describe ".run_id" do
    it "returns nil when E2E_RUN_ID is unset" do
      ENV.delete("E2E_RUN_ID")
      expect(described_class.run_id).to be_nil
    end

    it "returns nil when E2E_RUN_ID is empty" do
      ENV["E2E_RUN_ID"] = ""
      expect(described_class.run_id).to be_nil
    end

    it "returns the id when E2E_RUN_ID is set" do
      ENV["E2E_RUN_ID"] = "12345"
      expect(described_class.run_id).to eq("12345")
    end
  end

  describe ".labels_hash" do
    it "returns an empty hash outside E2E runs" do
      ENV.delete("E2E_RUN_ID")
      expect(described_class.labels_hash).to eq({})
    end

    it "returns a hash with the e2e_run_id label inside E2E runs" do
      ENV["E2E_RUN_ID"] = "98765"
      expect(described_class.labels_hash).to eq({"e2e_run_id" => "98765"})
    end
  end

  describe ".description_suffix" do
    it "returns an empty string outside E2E runs" do
      ENV.delete("E2E_RUN_ID")
      expect(described_class.description_suffix).to eq("")
    end

    it "returns a bracketed token inside E2E runs" do
      ENV["E2E_RUN_ID"] = "42"
      expect(described_class.description_suffix).to eq(" [e2e_run_id=42]")
    end
  end
end
