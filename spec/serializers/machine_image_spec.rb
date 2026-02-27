# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::MachineImage do
  describe ".serialize_internal" do
    let(:project) { Project.create(name: "test") }

    let(:vm) {
      instance_double(Vm, ubid: "vmtest1234567890123456")
    }

    let(:mi) {
      MachineImage.create(
        name: "test-image",
        description: "A test image",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        arch: "arm64"
      )
    }

    let(:version) {
      MachineImageVersion.create(
        machine_image_id: mi.id,
        version: 1,
        state: "available",
        size_gib: 20,
        s3_bucket: "test-bucket",
        s3_prefix: "images/test/",
        s3_endpoint: "https://r2.example.com"
      ).tap { it.activate! }
    }

    it "returns correct hash shape with active version" do
      version # create and activate
      mi.refresh

      result = described_class.serialize_internal(mi)

      expect(result[:id]).to eq(mi.ubid)
      expect(result[:name]).to eq("test-image")
      expect(result[:description]).to eq("A test image")
      expect(result[:location]).to eq("eu-central-h1")
      expect(result[:arch]).to eq("arm64")
      expect(result[:version]).to eq(1)
      expect(result[:state]).to eq("available")
      expect(result[:size_gib]).to eq(20)
      expect(result[:created_at]).to be_a(String)
      expect(result[:active_version]).to be_a(Hash)
      expect(result[:active_version][:id]).to eq(version.ubid)
      expect(result[:versions]).to be_an(Array)
      expect(result[:versions].length).to eq(1)
      expect(result).not_to have_key(:path)
    end

    it "returns nil active version fields when no active version" do
      result = described_class.serialize_internal(mi)

      expect(result[:version]).to be_nil
      expect(result[:state]).to be_nil
      expect(result[:size_gib]).to be_nil
      expect(result[:arch]).to eq("arm64")
      expect(result[:active_version]).to be_nil
      expect(result[:versions]).to eq([])
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

    it "serializes version with source vm" do
      ver = MachineImageVersion.create(
        machine_image_id: mi.id,
        version: 1,
        state: "available",
        size_gib: 10,
        vm_id: nil,
        s3_bucket: "test-bucket",
        s3_prefix: "images/test2/",
        s3_endpoint: "https://r2.example.com"
      )

      result = described_class.serialize_version(ver)

      expect(result[:source_vm_id]).to be_nil
      expect(result[:version]).to eq(1)
      expect(result[:state]).to eq("available")
      expect(result[:size_gib]).to eq(10)
      expect(result[:archive_size_mib]).to be_nil
      expect(result[:active]).to be false
    end
  end
end
