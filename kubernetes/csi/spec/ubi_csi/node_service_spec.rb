# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Csi::V1::NodeService do
  let(:service) { described_class.new }

  describe "constants" do
    it "defines MAX_VOLUMES_PER_NODE" do
      expect(described_class::MAX_VOLUMES_PER_NODE).to eq(8)
    end

    it "defines VOLUME_BASE_PATH" do
      expect(described_class::VOLUME_BASE_PATH).to eq("/var/lib/ubicsi")
    end

    it "defines LOGGER" do
      expect(described_class::LOGGER).to be_a(Logger)
    end

    it "defines OLD_PV_NAME_ANNOTATION_KEY" do
      expect(described_class::OLD_PV_NAME_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pv-name")
    end

    it "defines OLD_PVC_OBJECT_ANNOTATION_KEY" do
      expect(described_class::OLD_PVC_OBJECT_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pvc-object")
    end
  end

  describe "#log_with_id" do
    it "logs messages with request ID and service identifier" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#node_name" do
    context "when NODE_ID environment variable is set" do
      before do
        allow(ENV).to receive(:[]).with("NODE_ID").and_return("test-node")
      end

      it "returns the NODE_ID environment variable" do
        expect(service.node_name).to eq("test-node")
      end
    end

    context "when NODE_ID environment variable is not set" do
      before do
        allow(ENV).to receive(:[]).with("NODE_ID").and_return(nil)
      end

      it "returns nil" do
        expect(service.node_name).to be_nil
      end
    end
  end

  describe "class inheritance" do
    it "inherits from Node::Service" do
      expect(described_class.superclass).to eq(Csi::V1::Node::Service)
    end
  end

  describe "gRPC object creation and validation" do
    # Shared fixtures using let() for DRY
    let(:volume_capability) do
      {
        mount: { fs_type: "ext4", mount_flags: [], volume_mount_group: "" },
        access_mode: { mode: :SINGLE_NODE_WRITER }
      }
    end

    let(:base_volume_context) { { "storage.kubernetes.io/csiProvisionerIdentity" => "test" } }
    let(:base_publish_context) { { "devicePath" => "/dev/xvdf" } }

    describe "NodeStageVolumeRequest" do
      let(:stage_request) do
        Csi::V1::NodeStageVolumeRequest.new(
          volume_id: "test-vol-123",
          staging_target_path: "/var/lib/kubelet/staging/test-vol-123",
          volume_capability: volume_capability,
          publish_context: base_publish_context,
          volume_context: base_volume_context
        )
      end

      it "creates valid request with nested objects" do
        expect(stage_request.volume_id).to eq("test-vol-123")
        expect(stage_request.staging_target_path).to eq("/var/lib/kubelet/staging/test-vol-123")
        expect(stage_request.volume_capability.mount.fs_type).to eq("ext4")
        expect(stage_request.volume_capability.access_mode.mode).to eq(:SINGLE_NODE_WRITER)
      end

      it "handles custom filesystem types" do
        custom_request = Csi::V1::NodeStageVolumeRequest.new(
          volume_id: "xfs-vol",
          staging_target_path: "/mnt/test",
          volume_capability: {
            mount: { fs_type: "xfs", mount_flags: ["noatime", "nodiratime"] },
            access_mode: { mode: :SINGLE_NODE_WRITER }
          }
        )

        expect(custom_request.volume_capability.mount.fs_type).to eq("xfs")
        expect(custom_request.volume_capability.mount.mount_flags).to eq(["noatime", "nodiratime"])
      end
    end

    describe "NodePublishVolumeRequest" do
      let(:publish_request) do
        Csi::V1::NodePublishVolumeRequest.new(
          volume_id: "test-vol-456",
          staging_target_path: "/var/lib/kubelet/staging/test-vol-456",
          target_path: "/var/lib/kubelet/pods/test-pod/volumes/test-vol-456",
          volume_capability: volume_capability,
          readonly: false,
          publish_context: base_publish_context,
          volume_context: base_volume_context
        )
      end

      it "creates valid publish request" do
        expect(publish_request.volume_id).to eq("test-vol-456")
        expect(publish_request.readonly).to be false
        expect(publish_request.volume_capability.access_mode.mode).to eq(:SINGLE_NODE_WRITER)
      end

      context "with readonly mount" do
        let(:readonly_request) do
          Csi::V1::NodePublishVolumeRequest.new(
            volume_id: "readonly-vol",
            target_path: "/mnt/readonly",
            volume_capability: volume_capability,
            readonly: true
          )
        end

        it "handles readonly flag" do
          expect(readonly_request.readonly).to be true
          expect(readonly_request.volume_id).to eq("readonly-vol")
        end
      end
    end

    describe "complex nested structures" do
      it "creates requests with multiple volume capabilities" do
        multi_cap_request = Csi::V1::CreateVolumeRequest.new(
          name: "multi-capability-volume",
          volume_capabilities: [
            {
              mount: { fs_type: "ext4" },
              access_mode: { mode: :SINGLE_NODE_WRITER }
            },
            {
              block: {},
              access_mode: { mode: :MULTI_NODE_READER_ONLY }
            }
          ],
          capacity_range: { required_bytes: 1073741824, limit_bytes: 2147483648 }
        )

        expect(multi_cap_request.volume_capabilities.length).to eq(2)
        expect(multi_cap_request.volume_capabilities[0].mount.fs_type).to eq("ext4")
        expect(multi_cap_request.volume_capabilities[1].access_mode.mode).to eq(:MULTI_NODE_READER_ONLY)
      end

      it "creates topology requirements" do
        topo_request = Csi::V1::CreateVolumeRequest.new(
          name: "topology-volume",
          accessibility_requirements: {
            requisite: [
              { segments: { "zone" => "us-west-1a", "instance-type" => "m5.large" } },
              { segments: { "zone" => "us-west-1b", "instance-type" => "m5.large" } }
            ],
            preferred: [
              { segments: { "zone" => "us-west-1a" } }
            ]
          }
        )

        expect(topo_request.accessibility_requirements.requisite.length).to eq(2)
        expect(topo_request.accessibility_requirements.requisite[0].segments["zone"]).to eq("us-west-1a")
        expect(topo_request.accessibility_requirements.preferred[0].segments["zone"]).to eq("us-west-1a")
      end
    end
  end
end

