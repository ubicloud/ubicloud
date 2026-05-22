# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Option do
  describe "#VmSize options" do
    it "no burstable cpu allowed for Standard VMs" do
      expect(Option::VmSizes.map { it.name.include?("burstable-") == (it.cpu_burst_percent_limit > 0) }.all?(true)).to be true
    end

    it "no odd number of vcpus allowed, except for 1" do
      expect(Option::VmSizes.all? { it.vcpus == 1 || it.vcpus.even? }).to be true
    end
  end

  describe "#VmFamily options" do
    it "families include burstables" do
      expect(described_class.families.map(&:name)).to include("burstable")
    end
  end

  describe "GCP Postgres options" do
    it "defines all GCP family options" do
      expect(Option::GCP_FAMILY_OPTIONS).to eq(["c4a-standard", "c4a-highmem"])
    end

    it "includes GCP families in POSTGRES_FAMILY_OPTIONS" do
      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(Option::POSTGRES_FAMILY_OPTIONS).to have_key(family)
      end
    end

    it "defines GCP storage options for all families" do
      Option::GCP_FAMILY_OPTIONS.each do |family|
        expect(Option::GCP_STORAGE_SIZE_OPTIONS).to have_key(family)
      end
    end

    it "has a single fixed storage value per GCP family and vcpu" do
      Option::GCP_STORAGE_SIZE_OPTIONS.each do |family, vcpu_map|
        vcpu_map.each do |vcpu, storage_options|
          expect(storage_options.length).to eq(1), "Expected 1 storage option for #{family} #{vcpu} vCPUs, got #{storage_options.length}"
        end
      end
    end

    it "has matching size options for each GCP family and vcpu" do
      Option::GCP_STORAGE_SIZE_OPTIONS.each do |family, vcpu_map|
        vcpu_map.each_key do |vcpu|
          size_name = "#{family}-#{vcpu}"
          expect(Option::POSTGRES_SIZE_OPTIONS).to have_key(size_name), "Missing POSTGRES_SIZE_OPTIONS entry for #{size_name}"
          expect(Option::POSTGRES_SIZE_OPTIONS[size_name].family).to eq(family)
          expect(Option::POSTGRES_SIZE_OPTIONS[size_name].vcpu_count).to eq(vcpu)
        end
      end
    end

    it "uses correct memory coefficients for GCP families" do
      # standard: 4 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-standard-8"].memory_gib).to eq(32)
      # highmem: 8 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-highmem-8"].memory_gib).to eq(64)
    end
  end

  describe "POSTGRES_FAMILY_FALLBACK_CHAINS" do
    it "matches the derivation from POSTGRES_SIZE_OPTIONS" do
      derived = (Option::POSTGRES_SIZE_OPTIONS.values.map(&:family).uniq & Option::AWS_FAMILY_OPTIONS)
        .group_by { it.sub(/\d+/, "") }
        .values
        .map { |chain| chain.sort_by { it[/\d+/].to_i } }
        .reject { |chain| chain.size < 2 }
      expect(Option::POSTGRES_FAMILY_FALLBACK_CHAINS).to eq(derived)
    end
  end

  describe ".postgres_fallback_candidates" do
    it "returns the older family for the newest in a 2-element chain" do
      expect(described_class.postgres_fallback_candidates("m8id")).to eq(["m6id"])
    end

    it "returns the newer family for the oldest in a 2-element chain" do
      expect(described_class.postgres_fallback_candidates("m6id")).to eq(["m8id"])
    end

    it "returns all older alternatives for the newest in a 3-element chain" do
      expect(described_class.postgres_fallback_candidates("c8gd")).to eq(["c6gd", "c7gd"])
    end

    it "returns all newer alternatives for the oldest in a 3-element chain" do
      expect(described_class.postgres_fallback_candidates("c6gd")).to eq(["c7gd", "c8gd"])
    end

    it "returns older alternatives first then newer for a mid-chain family" do
      expect(described_class.postgres_fallback_candidates("c7gd")).to eq(["c6gd", "c8gd"])
    end

    it "returns empty list for a family not in any chain" do
      expect(described_class.postgres_fallback_candidates("standard")).to eq([])
    end
  end

  describe ".postgres_family_rank" do
    it "returns the chain index for a 2-element chain" do
      expect(described_class.postgres_family_rank("m6id")).to eq(0)
      expect(described_class.postgres_family_rank("m8id")).to eq(1)
    end

    it "returns the chain index for a 3-element chain" do
      expect(described_class.postgres_family_rank("c6gd")).to eq(0)
      expect(described_class.postgres_family_rank("c7gd")).to eq(1)
      expect(described_class.postgres_family_rank("c8gd")).to eq(2)
    end

    it "returns -1 for a family not in any chain" do
      expect(described_class.postgres_family_rank("standard")).to eq(-1)
    end
  end

  describe "#kubernetes_upgrade_candidate" do
    it "returns upgrade version for upgradeable version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.33")).to eq("v1.34")
      expect(described_class.kubernetes_upgrade_candidate("v1.34")).to eq("v1.35")
      expect(described_class.kubernetes_upgrade_candidate("v1.35")).to eq("v1.36")
    end

    it "returns nil for latest version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.31")).to be_nil
    end
  end
end
