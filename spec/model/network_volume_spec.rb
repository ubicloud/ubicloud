# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NetworkVolume do
  let(:project) { Project.create(name: "test-project") }
  let(:aws_location) {
    Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS", visible: true)
  }
  let(:gcp_location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "gcp-us-central1", ui_name: "GCP", visible: true)
  }

  describe "#config" do
    it "resolves to the aws side table on an aws location" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      AwsVolume.create_with_id(nv, volume_type: "io2", provisioned_iops: 8000)

      expect(nv.config).to be_a(AwsVolume)
      expect(nv.volume_type).to eq("io2")
      expect(nv.config.provisioned_iops).to eq(8000)
    end

    it "resolves to the gcp side table on a gcp location" do
      nv = described_class.create(location_id: gcp_location.id, size_gib: 64)
      GcpVolume.create_with_id(nv, volume_type: "hyperdisk-balanced")

      expect(nv.config).to be_a(GcpVolume)
      expect(nv.volume_type).to eq("hyperdisk-balanced")
    end

    it "raises on metal, which has no network volumes" do
      nv = described_class.create(location_id: Location::HETZNER_FSN1_ID, size_gib: 64)

      expect { nv.config }.to raise_error(RuntimeError, /not supported on metal/)
    end
  end

  describe "#limits" do
    it "reads the type's envelope through the side table" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      AwsVolume.create_with_id(nv, volume_type: "gp3")

      expect(nv.limits.iops).to eq(3000..80_000)
      expect(nv.limits).to be_configurable_throughput
    end

    it "reports io2 as deriving its own throughput" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      AwsVolume.create_with_id(nv, volume_type: "io2")

      expect(nv.limits).not_to be_configurable_throughput
    end
  end

  describe "#attached?" do
    it "is false until an attachment references it, and true after" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      expect(nv.attached?).to be false

      vm = create_vm(location_id: aws_location.id)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 9, network_volume_id: nv.id)

      expect(nv.reload.attached?).to be true
    end
  end

  describe "identity" do
    it "owns the ubid, which the per-provider config rows share" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      config = AwsVolume.create_with_id(nv, volume_type: "gp3")

      expect(nv.ubid).to start_with("nv")
      expect(config.ubid).to eq(nv.ubid)
    end
  end

  describe "lifetime" do
    it "is destroyed with the attachment, taking its configuration with it" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      AwsVolume.create_with_id(nv, volume_type: "gp3")
      vm = create_vm(location_id: aws_location.id)
      attachment = VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 9, network_volume_id: nv.id)

      attachment.destroy

      expect(described_class[nv.id]).to be_nil
      expect(AwsVolume[nv.id]).to be_nil
    end

    it "cannot be mounted by two VMs at once" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)
      vm = create_vm(location_id: aws_location.id)
      other = create_vm(location_id: aws_location.id)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 9, network_volume_id: nv.id)

      expect { VmStorageVolume.create(vm_id: other.id, boot: false, size_gib: 64, disk_index: 9, network_volume_id: nv.id) }
        .to raise_error(Sequel::ValidationFailed, /network_volume_id is already taken/)
    end
  end

  describe "database constraints" do
    it "rejects a non-positive size" do
      expect { described_class.create(location_id: aws_location.id, size_gib: 0) }
        .to raise_error(Sequel::ValidationFailed, /size_gib is invalid/)
    end

    it "confines aws volumes to EBS types" do
      nv = described_class.create(location_id: aws_location.id, size_gib: 64)

      expect { AwsVolume.create_with_id(nv, volume_type: "hyperdisk-balanced") }
        .to raise_error(Sequel::ValidationFailed, /volume_type is invalid/)
    end

    it "confines gcp volumes to hyperdisk" do
      nv = described_class.create(location_id: gcp_location.id, size_gib: 64)

      expect { GcpVolume.create_with_id(nv, volume_type: "gp3") }
        .to raise_error(Sequel::ValidationFailed, /volume_type is invalid/)
    end

    it "does not let configuration exist without its volume" do
      expect { AwsVolume.create(volume_type: "gp3") { it.id = described_class.generate_uuid } }
        .to raise_error(Sequel::ValidationFailed, /id is invalid/)
    end
  end
end
