# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::MachineImage do
  describe ".serialize_internal" do
    let(:project) { Project.create(name: "test") }

    let(:vm) {
      instance_double(Vm, ubid: "vmtest1234567890123456")
    }

    let(:mi) {
      mi = MachineImage.create(
        name: "test-image",
        description: "A test image",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        state: "available",
        s3_bucket: "test-bucket",
        s3_prefix: "images/test/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 20,
        encrypted: true,
        compression: "zstd",
        visible: false
      )
      allow(mi).to receive(:vm).and_return(vm)
      mi
    }

    it "returns correct hash shape" do
      result = described_class.serialize_internal(mi)

      expect(result[:id]).to eq(mi.ubid)
      expect(result[:name]).to eq("test-image")
      expect(result[:description]).to eq("A test image")
      expect(result[:state]).to eq("available")
      expect(result[:size_gib]).to eq(20)
      expect(result[:encrypted]).to be true
      expect(result[:compression]).to eq("zstd")
      expect(result[:visible]).to be false
      expect(result[:location]).to eq("eu-central-h1")
      expect(result[:source_vm_id]).to eq("vmtest1234567890123456")
      expect(result[:created_at]).to be_a(String)
      expect(result).not_to have_key(:path)
    end

    it "includes path when include_path option is set" do
      result = described_class.serialize_internal(mi, {include_path: true})

      expect(result[:path]).to eq("/location/eu-central-h1/machine-image/#{mi.ubid}")
    end

    it "does not include path when include_path is not set" do
      result = described_class.serialize_internal(mi)

      expect(result).not_to have_key(:path)
    end

    it "handles nil created_at" do
      allow(mi).to receive(:created_at).and_return(nil)
      result = described_class.serialize_internal(mi)
      expect(result[:created_at]).to be_nil
    end

    it "handles nil vm" do
      mi_no_vm = MachineImage.create(
        name: "no-vm-image",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        state: "available",
        s3_bucket: "test-bucket",
        s3_prefix: "images/test2/",
        s3_endpoint: "https://r2.example.com",
        size_gib: 10
      )

      result = described_class.serialize_internal(mi_no_vm)

      expect(result[:source_vm_id]).to be_nil
    end
  end
end
