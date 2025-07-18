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

    it "defines OLD_PV_NAME_ANNOTATION_KEY" do
      expect(described_class::OLD_PV_NAME_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pv-name")
    end

    it "defines OLD_PVC_OBJECT_ANNOTATION_KEY" do
      expect(described_class::OLD_PVC_OBJECT_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pvc-object")
    end
  end

  describe "#node_get_capabilities" do
    let(:call) { instance_double("GRPC::ActiveCall") }
    let(:request) { Csi::V1::NodeGetCapabilitiesRequest.new }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
      allow(service).to receive(:log_with_id)
    end

    it "returns node capabilities with STAGE_UNSTAGE_VOLUME" do
      response = service.node_get_capabilities(request, call)
      
      expect(response).to be_a(Csi::V1::NodeGetCapabilitiesResponse)
      expect(response.capabilities.length).to eq(1)
      expect(response.capabilities.first.rpc.type).to eq(:STAGE_UNSTAGE_VOLUME)
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /node_get_capabilities request/).ordered
      expect(service).to receive(:log_with_id).with("test-uuid", /node_get_capabilities response/).ordered
      
      service.node_get_capabilities(request, call)
    end
  end

  describe "#node_get_info" do
    let(:call) { instance_double("GRPC::ActiveCall") }
    let(:request) { Csi::V1::NodeGetInfoRequest.new }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
      allow(service).to receive(:log_with_id)
      allow(service).to receive(:node_name).and_return("test-node")
    end

    it "returns node information" do
      response = service.node_get_info(request, call)
      
      expect(response).to be_a(Csi::V1::NodeGetInfoResponse)
      expect(response.node_id).to eq("test-node")
      expect(response.max_volumes_per_node).to eq(8)
      expect(response.accessible_topology.segments["kubernetes.io/hostname"]).to eq("test-node")
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /node_get_info request/).ordered
      expect(service).to receive(:log_with_id).with("test-uuid", /node_get_info response/).ordered
      
      service.node_get_info(request, call)
    end
  end

  describe "helper methods" do
    describe "#node_name" do
      it "returns NODE_ID environment variable" do
        allow(ENV).to receive(:[]).with("NODE_ID").and_return("test-node")
        expect(service.node_name).to eq("test-node")
      end
    end

    describe "#log_with_id" do
      it "logs with request ID prefix" do
        expect(described_class::LOGGER).to receive(:info).with("[req_id=test-123] [CSI NodeService] test message")
        service.log_with_id("test-123", "test message")
      end
    end

    describe ".backing_file_path" do
      it "returns correct backing file path" do
        expect(described_class.backing_file_path("vol-123")).to eq("/var/lib/ubicsi/vol-123.img")
      end
    end

    describe "#run_cmd" do
      it "executes command and returns output and status" do
        allow(Open3).to receive(:capture2e).with("echo", "test").and_return(["output", 0])
        
        output, status = service.run_cmd("echo", "test")
        expect(output).to eq("output")
        expect(status).to eq(0)
      end

      it "logs command when req_id is provided" do
        allow(Open3).to receive(:capture2e).and_return(["", 0])
        expect(described_class::LOGGER).to receive(:info).with(/test-req.*Running command.*echo.*test/)
        
        service.run_cmd("echo", "test", req_id: "test-req")
      end

      it "does not log when req_id is nil" do
        allow(Open3).to receive(:capture2e).and_return(["", 0])
        expect(described_class::LOGGER).not_to receive(:info)
        
        service.run_cmd("echo", "test", req_id: nil)
      end
    end

    describe "#run_cmd_output" do
      it "extracts output from run_cmd result" do
        allow(service).to receive(:run_cmd).with("echo", "test", req_id: nil).and_return(["extracted_output", 0])
        
        result = service.run_cmd_output("echo", "test")
        expect(result).to eq("extracted_output")
      end
    end

    describe "#is_mounted?" do
      it "returns true when path is mounted" do
        allow(service).to receive(:run_cmd).with("mountpoint", "-q", "/mnt/test", req_id: nil).and_return(["", 0])
        expect(service.is_mounted?("/mnt/test")).to be true
      end

      it "returns false when path is not mounted" do
        allow(service).to receive(:run_cmd).with("mountpoint", "-q", "/mnt/test", req_id: nil).and_return(["", 1])
        expect(service.is_mounted?("/mnt/test")).to be false
      end
    end

    describe "#find_loop_device" do
      it "returns loop device when found" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["/dev/loop0: [2049]:123456 (/path/to/file)", true])
        expect(service.find_loop_device("/path/to/file")).to eq("/dev/loop0")
      end

      it "returns nil when not found" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["", true])
        expect(service.find_loop_device("/path/to/file")).to be_nil
      end

      it "returns nil when command fails" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["some output", false])
        expect(service.find_loop_device("/path/to/file")).to be_nil
      end
    end

    describe "#pvc_needs_migration?" do
      it "returns true when old PV name annotation exists" do
        pvc = {
          "metadata" => {
            "annotations" => {
              "csi.ubicloud.com/old-pv-name" => "old-pv-123"
            }
          }
        }
        expect(service.pvc_needs_migration?(pvc)).to be true
      end

      it "returns false when old PV name annotation is missing" do
        pvc = { "metadata" => { "annotations" => {} } }
        expect(service.pvc_needs_migration?(pvc)).to be false
      end

      it "returns false when metadata is missing" do
        pvc = {}
        expect(service.pvc_needs_migration?(pvc)).to be false
      end
    end
  end

  describe "gRPC object creation" do
    it "creates valid NodeGetCapabilitiesResponse" do
      response = Csi::V1::NodeGetCapabilitiesResponse.new(
        capabilities: [
          Csi::V1::NodeServiceCapability.new(
            rpc: Csi::V1::NodeServiceCapability::RPC.new(
              type: Csi::V1::NodeServiceCapability::RPC::Type::STAGE_UNSTAGE_VOLUME
            )
          )
        ]
      )
      expect(response.capabilities.length).to eq(1)
    end

    it "creates valid NodeGetInfoResponse" do
      response = Csi::V1::NodeGetInfoResponse.new(
        node_id: "test-node",
        max_volumes_per_node: 8,
        accessible_topology: Csi::V1::Topology.new(
          segments: { "kubernetes.io/hostname" => "test-node" }
        )
      )
      expect(response.node_id).to eq("test-node")
    end
  end

  # Additional tests to cover uncovered branches systematically
  describe "branch coverage improvements" do
    describe "#find_loop_device" do
      it "returns nil when command fails" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["", false])
        expect(service.find_loop_device("/path/to/file")).to be_nil
      end

      it "returns nil when output is empty" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["", true])
        expect(service.find_loop_device("/path/to/file")).to be_nil
      end

      it "returns nil when loop device doesn't start with /dev/loop" do
        allow(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file").and_return(["invalid: output", true])
        expect(service.find_loop_device("/path/to/file")).to be_nil
      end
    end

    describe "#fetch_and_migrate_pvc" do
      let(:req_id) { "test-req-id" }
      let(:client) { instance_double(Csi::KubernetesClient) }
      let(:req) do
        instance_double("Request", volume_context: {
          "csi.storage.k8s.io/pvc/namespace" => "default",
          "csi.storage.k8s.io/pvc/name" => "test-pvc"
        })
      end
      let(:pvc) { { "metadata" => { "annotations" => {} } } }

      before do
        allow(service).to receive(:log_with_id)
      end

      it "returns PVC without migration when not needed" do
        allow(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        allow(service).to receive(:pvc_needs_migration?).with(pvc).and_return(false)
        
        result = service.fetch_and_migrate_pvc(req_id, client, req)
        expect(result).to eq(pvc)
      end

      it "migrates PVC data when migration is needed" do
        pvc_with_migration = { "metadata" => { "annotations" => { "csi.ubicloud.com/old-pv-name" => "old-pv" } } }
        allow(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc_with_migration)
        allow(service).to receive(:pvc_needs_migration?).with(pvc_with_migration).and_return(true)
        allow(service).to receive(:migrate_pvc_data).with(req_id, client, pvc_with_migration, req)
        
        result = service.fetch_and_migrate_pvc(req_id, client, req)
        expect(result).to eq(pvc_with_migration)
      end

      it "handles CopyNotFinishedError" do
        allow(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        allow(service).to receive(:pvc_needs_migration?).with(pvc).and_return(true)
        allow(service).to receive(:migrate_pvc_data).and_raise(CopyNotFinishedError, "Copy in progress")
        
        expect(service).to receive(:log_with_id).with(req_id, /Waiting for data copy to finish/)
        expect { service.fetch_and_migrate_pvc(req_id, client, req) }.to raise_error(GRPC::Internal, "13:Copy in progress")
      end

      it "handles unexpected errors" do
        allow(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        allow(service).to receive(:pvc_needs_migration?).with(pvc).and_return(true)
        allow(service).to receive(:migrate_pvc_data).and_raise(StandardError, "Unexpected error")
        
        expect(service).to receive(:log_with_id).with(req_id, /Internal error in node_stage_volume/)
        expect { service.fetch_and_migrate_pvc(req_id, client, req) }.to raise_error(GRPC::Internal, /Unexpected error/)
      end
    end
  end

  describe "perform_node_stage_volume branches" do
      let(:req_id) { "test-req-id" }
      let(:volume_id) { "vol-test-123" }
      let(:size_bytes) { 1024 * 1024 * 1024 }
      let(:backing_file) { "/var/lib/ubicsi/vol-test-123.img" }
      let(:staging_path) { "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/test-pv/globalmount" }
      let(:pvc) { { "metadata" => { "annotations" => {} } } }
      let(:req) do
        instance_double("Request",
          volume_id: volume_id,
          staging_target_path: staging_path,
          volume_context: { "size_bytes" => size_bytes.to_s },
          volume_capability: instance_double("VolumeCapability",
            mount: instance_double("Mount", fs_type: "ext4")
          )
        )
      end
      
      before do
        allow(service).to receive(:log_with_id)
        allow(Csi::V1::NodeService).to receive(:backing_file_path).with(volume_id).and_return(backing_file)
        # Mock the complex parts we're not testing
        allow(service).to receive(:find_loop_device).and_return(nil)
        allow(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["/dev/loop0", true])
        allow(service).to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id).and_return(["", true])
        allow(Dir).to receive(:exist?).with(staging_path).and_return(false)
        allow(FileUtils).to receive(:mkdir_p)
        allow(service).to receive(:run_cmd).with("mount", "/dev/loop0", staging_path, req_id: req_id).and_return(["", true])
        allow(service).to receive(:is_mounted?).and_return(false)
        allow(service).to receive(:is_copied_pvc).and_return(false)
      end

      describe "directory creation logic" do
        it "skips directory creation when directory exists" do
          allow(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(true)
          expect(FileUtils).not_to receive(:mkdir_p).with("/var/lib/ubicsi")
          allow(File).to receive(:exist?).with(backing_file).and_return(true)
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end

        it "creates directory when it doesn't exist" do
          allow(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(false)
          expect(FileUtils).to receive(:mkdir_p).with("/var/lib/ubicsi")
          allow(File).to receive(:exist?).with(backing_file).and_return(true)
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end
      end

      describe "backing file creation logic" do
        before do
          allow(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(true)
        end

        it "skips file creation when file exists" do
          allow(File).to receive(:exist?).with(backing_file).and_return(true)
          expect(service).not_to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id)
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end

        it "creates file when it doesn't exist - success path" do
          allow(File).to receive(:exist?).with(backing_file).and_return(false)
          expect(service).to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["", true])
          expect(service).to receive(:run_cmd).with("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["", true])
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end

        it "handles fallocate failure" do
          allow(File).to receive(:exist?).with(backing_file).and_return(false)
          allow(service).to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["Error message", false])
          
          expect(service).to receive(:log_with_id).with(req_id, /failed to fallocate/)
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::ResourceExhausted, /Failed to allocate backing file/)
        end

        it "handles punch hole failure" do
          allow(File).to receive(:exist?).with(backing_file).and_return(false)
          allow(service).to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["", true])
          allow(service).to receive(:run_cmd).with("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["Punch hole error", false])
          
          expect(service).to receive(:log_with_id).with(req_id, /failed to punchhole/)
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::ResourceExhausted, /Failed to punch hole/)
        end
      end
    end


end

