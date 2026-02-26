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
      expect(Option::GCP_FAMILY_OPTIONS).to eq(["c4a-standard", "c4a-highmem", "c3-standard", "c3d-standard", "c3d-highmem"])
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
      # standard families: 4 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-standard-8"].memory_gib).to eq(32)
      expect(Option::POSTGRES_SIZE_OPTIONS["c3-standard-22"].memory_gib).to eq(88)
      expect(Option::POSTGRES_SIZE_OPTIONS["c3d-standard-30"].memory_gib).to eq(120)

      # highmem families: 8 GiB/vCPU
      expect(Option::POSTGRES_SIZE_OPTIONS["c4a-highmem-8"].memory_gib).to eq(64)
      expect(Option::POSTGRES_SIZE_OPTIONS["c3d-highmem-30"].memory_gib).to eq(240)
    end
  end
end
