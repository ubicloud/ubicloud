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

      describe "loop device logic" do
        before do
          allow(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(true)
          allow(File).to receive(:exist?).with(backing_file).and_return(true)
        end

        it "handles loop device setup failure" do
          allow(service).to receive(:find_loop_device).and_return(nil)
          allow(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["Error setting up loop device", false])
          
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to setup loop device/)
        end

        it "handles empty loop device output" do
          allow(service).to receive(:find_loop_device).and_return(nil)
          allow(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["", true])
          
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to setup loop device/)
        end

        it "logs when loop device already exists" do
          allow(service).to receive(:find_loop_device).and_return("/dev/loop1")
          allow(service).to receive(:run_cmd).with("mount", "/dev/loop1", staging_path, req_id: req_id).and_return(["", true])
          expect(service).to receive(:log_with_id).with(req_id, "Loop device already exists: /dev/loop1")
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end
      end

      describe "filesystem creation logic" do
        before do
          allow(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(true)
          allow(File).to receive(:exist?).with(backing_file).and_return(true)
          allow(service).to receive(:find_loop_device).and_return("/dev/loop0")
        end

        it "skips mkfs when PVC is copied" do
          allow(service).to receive(:is_copied_pvc).and_return(true)
          expect(service).not_to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id)
          
          service.perform_node_stage_volume(req_id, pvc, req, nil)
        end

        it "handles mkfs failure" do
          allow(service).to receive(:find_loop_device).and_return(nil)  # New loop device
          allow(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["/dev/loop0", true])
          allow(service).to receive(:is_copied_pvc).and_return(false)
          allow(service).to receive(:is_mounted?).and_return(false)
          allow(FileUtils).to receive(:mkdir_p)
          allow(service).to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id).and_return(["mkfs error", false])
          
          expect(service).to receive(:log_with_id).with(req_id, /failed to format device/)
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to format device/)
        end

        it "handles mount failure" do
          allow(service).to receive(:find_loop_device).and_return("/dev/loop0")
          allow(service).to receive(:is_copied_pvc).and_return(false)
          allow(service).to receive(:is_mounted?).and_return(false)
          allow(FileUtils).to receive(:mkdir_p)
          allow(service).to receive(:run_cmd).with("mount", "/dev/loop0", staging_path, req_id: req_id).and_return(["mount error", false])
          
          expect(service).to receive(:log_with_id).with(req_id, /failed to mount loop device/)
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to mount/)
        end

        it "handles general exceptions" do
          allow(service).to receive(:find_loop_device).and_raise(StandardError, "Unexpected error")
          
          expect(service).to receive(:log_with_id).with(req_id, /Internal error in node_stage_volume/)
          expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /NodeStageVolume error/)
        end
      end
    end

  describe "#node_stage_volume" do
    let(:req) do
      Csi::V1::NodeStageVolumeRequest.new(
        volume_id: "vol-test-123",
        staging_target_path: "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/test-pv/globalmount",
        volume_capability: Csi::V1::VolumeCapability.new(
          mount: Csi::V1::VolumeCapability::MountVolume.new(fs_type: "ext4")
        ),
        volume_context: { "size_bytes" => "1073741824" }
      )
    end
    let(:pvc) { { "metadata" => { "annotations" => {} } } }
    let(:response) { Csi::V1::NodeStageVolumeResponse.new }

    it "stages a volume successfully" do
      allow(service).to receive(:log_with_id)
      allow(Csi::KubernetesClient).to receive(:new).and_return(instance_double("KubernetesClient"))
      allow(service).to receive(:fetch_and_migrate_pvc).and_return(pvc)
      allow(service).to receive(:perform_node_stage_volume).and_return(response)
      allow(service).to receive(:roll_back_reclaim_policy)
      allow(service).to receive(:remove_old_pv_annotation)

      result = service.node_stage_volume(req, nil)
      expect(result).to eq(response)
    end
  end

  describe "#remove_old_pv_annotation" do
    let(:client) { instance_double("KubernetesClient") }

    it "removes old PV annotation when present" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
      
      expect(client).to receive(:update_pvc).with(pvc)
      service.remove_old_pv_annotation(client, pvc)
      
      expect(pvc["metadata"]["annotations"]["csi.ubicloud.com/old-pv-name"]).to be_nil
    end

    it "does nothing when annotation is not present" do
      pvc = {
        "metadata" => {
          "annotations" => {}
        }
      }
      
      expect(client).not_to receive(:update_pvc)
      service.remove_old_pv_annotation(client, pvc)
    end
  end

  describe "#roll_back_reclaim_policy" do
    let(:req_id) { "test-req-id" }
    let(:client) { instance_double("KubernetesClient") }
    let(:req) { instance_double("Request") }

    it "returns early when old PV name annotation is not present" do
      pvc = {
        "metadata" => {
          "annotations" => {}
        }
      }
      
      expect(client).not_to receive(:get_pv)
      service.roll_back_reclaim_policy(req_id, client, req, pvc)
    end

    it "updates PV reclaim policy when old PV has Retain policy" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
      pv = {
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Retain"
        }
      }
      
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      expect(client).to receive(:update_pv).with(pv)
      
      service.roll_back_reclaim_policy(req_id, client, req, pvc)
      expect(pv["spec"]["persistentVolumeReclaimPolicy"]).to eq("Delete")
    end

    it "does not update PV when reclaim policy is not Retain" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
      pv = {
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Delete"
        }
      }
      
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      expect(client).not_to receive(:update_pv)
      
      service.roll_back_reclaim_policy(req_id, client, req, pvc)
    end

    it "handles exceptions and converts to GRPC::Internal" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
      
      allow(client).to receive(:get_pv).with("old-pv-123").and_raise(StandardError, "Kubernetes API error")
      expect(service).to receive(:log_with_id).with(req_id, /Internal error in node_stage_volume/)
      
      expect { service.roll_back_reclaim_policy(req_id, client, req, pvc) }.to raise_error(GRPC::Internal, /Unexpected error/)
    end
  end

  describe "#is_copied_pvc" do
    it "returns true when PVC needs migration" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
      
      expect(service.is_copied_pvc(pvc)).to be true
    end

    it "returns false when PVC does not need migration" do
      pvc = {
        "metadata" => {
          "annotations" => {}
        }
      }
      
      expect(service.is_copied_pvc(pvc)).to be false
    end
  end

  describe "#migrate_pvc_data" do
    let(:req_id) { "test-req-id" }
    let(:client) { instance_double("KubernetesClient") }
    let(:req) { instance_double("Request", volume_id: "vol-new-123") }
    let(:pvc) do
      {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }
    end
    let(:pv) do
      {
        "spec" => {
          "csi" => {
            "volumeHandle" => "vol-old-123"
          }
        }
      }
    end

    it "handles migration when daemonizer check returns Succeeded" do
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      allow(client).to receive(:extract_node_from_pv).with(pv).and_return("worker-1")
      allow(client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
      allow(service).to receive(:run_cmd_output).and_return("Succeeded")
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "clean", "copy_old-pv-123", req_id: req_id)

      service.migrate_pvc_data(req_id, client, pvc, req)
    end

    it "handles migration when daemonizer check returns NotStarted" do
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      allow(client).to receive(:extract_node_from_pv).with(pv).and_return("worker-1")
      allow(client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
      
      # First call is the check, second call is the run
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", "copy_old-pv-123", req_id: req_id).and_return("NotStarted")
      allow(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "run", any_args)

      expect { service.migrate_pvc_data(req_id, client, pvc, req) }.to raise_error(CopyNotFinishedError, "Old PV data is not copied yet")
    end

    it "handles migration when daemonizer check returns InProgress" do
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      allow(client).to receive(:extract_node_from_pv).with(pv).and_return("worker-1")
      allow(client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
      
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", "copy_old-pv-123", req_id: req_id).and_return("InProgress")

      expect { service.migrate_pvc_data(req_id, client, pvc, req) }.to raise_error(CopyNotFinishedError, "Old PV data is not copied yet")
    end

    it "handles migration when daemonizer check returns Failed" do
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      allow(client).to receive(:extract_node_from_pv).with(pv).and_return("worker-1")
      allow(client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
      
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", "copy_old-pv-123", req_id: req_id).and_return("Failed")

      expect { service.migrate_pvc_data(req_id, client, pvc, req) }.to raise_error(RuntimeError, "Copy old PV data failed")
    end

    it "handles migration when daemonizer check returns unknown status" do
      allow(client).to receive(:get_pv).with("old-pv-123").and_return(pv)
      allow(client).to receive(:extract_node_from_pv).with(pv).and_return("worker-1")
      allow(client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
      
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", "copy_old-pv-123", req_id: req_id).and_return("UnknownStatus")

      expect { service.migrate_pvc_data(req_id, client, pvc, req) }.to raise_error(RuntimeError, "Daemonizer2 returned unknown status")
    end


  end

  describe "#node_unstage_volume" do
    let(:req) { instance_double("Request", volume_id: "vol-test-123", staging_target_path: "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount") }
    let(:client) { instance_double("KubernetesClient") }
    let(:response) { instance_double("NodeUnstageVolumeResponse") }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-req-id")
      allow(service).to receive(:log_with_id)
      allow(Csi::KubernetesClient).to receive(:new).with(req_id: "test-req-id").and_return(client)
      allow(Csi::V1::NodeUnstageVolumeResponse).to receive(:new).and_return(response)
    end

    it "unstages a volume successfully when node is schedulable" do
      allow(client).to receive(:node_schedulable?).with(service.node_name).and_return(true)

      result = service.node_unstage_volume(req, nil)
      expect(result).to eq(response)
    end

    it "prepares data migration when node is not schedulable" do
      allow(client).to receive(:node_schedulable?).with(service.node_name).and_return(false)
      expect(service).to receive(:prepare_data_migration).with(client, "test-req-id", "vol-test-123")

      result = service.node_unstage_volume(req, nil)
      expect(result).to eq(response)
    end

    it "handles errors and raises GRPC::Internal" do
      allow(client).to receive(:node_schedulable?).with(service.node_name).and_raise(StandardError, "Test error")

      expect { service.node_unstage_volume(req, nil) }.to raise_error(GRPC::Internal, "13:Unexpected error: StandardError - Test error")
    end
  end

  describe "#perform_node_unstage_volume" do
    let(:req_id) { "test-req-id" }
    let(:req) { instance_double("Request", staging_target_path: "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount") }
    let(:response) { instance_double("NodeUnstageVolumeResponse") }

    before do
      allow(service).to receive(:log_with_id)
      allow(Csi::V1::NodeUnstageVolumeResponse).to receive(:new).and_return(response)
    end

    it "handles umount failure when staging path is mounted" do
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount").and_return(true)
      allow(service).to receive(:run_cmd).with("umount", "-q", "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id: req_id).and_return(["umount: device is busy", false])

      expect { service.perform_node_unstage_volume(req_id, req, nil) }.to raise_error(GRPC::Internal, "13:Failed to unmount /var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount: umount: device is busy")
    end

    it "skips umount when staging path is not mounted" do
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount").and_return(false)

      result = service.perform_node_unstage_volume(req_id, req, nil)
      expect(result).to eq(response)
    end

    it "handles GRPC::BadStatus exceptions" do
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount").and_raise(GRPC::InvalidArgument, "Invalid argument")

      expect { service.perform_node_unstage_volume(req_id, req, nil) }.to raise_error(GRPC::InvalidArgument, "3:Invalid argument")
    end

    it "handles general exceptions and converts to GRPC::Internal" do
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount").and_raise(StandardError, "Unexpected error")
      expect { service.perform_node_unstage_volume(req_id, req, nil) }.to raise_error(GRPC::Internal, "13:NodeUnstageVolume error: Unexpected error")
    end
  end

  describe "#prepare_data_migration" do
    let(:req_id) { "test-req-id" }
    let(:volume_id) { "vol-test-123" }
    let(:client) { instance_double("KubernetesClient") }
    let(:pv) { { "metadata" => { "name" => "pv-123" } } }

    it "retains PV and recreates PVC" do
      expect(service).to receive(:log_with_id).with(req_id, /Retaining pv with volume_id/)
      expect(service).to receive(:retain_pv).with(req_id, client, volume_id).and_return(pv)
      expect(service).to receive(:log_with_id).with(req_id, /Recreating pvc with volume_id/)
      expect(service).to receive(:recreate_pvc).with(req_id, client, pv)
      
      service.prepare_data_migration(client, req_id, volume_id)
    end
  end

  describe "#retain_pv" do
    let(:req_id) { "test-req-id" }
    let(:volume_id) { "vol-test-123" }
    let(:client) { instance_double("KubernetesClient") }

    it "updates PV reclaim policy when it's not Retain" do
      pv = {
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Delete"
        }
      }
      
      allow(client).to receive(:find_pv_by_volume_id).with(volume_id).and_return(pv)
      expect(service).to receive(:log_with_id).with(req_id, /Found PV with volume_id/)
      expect(client).to receive(:update_pv).with(pv)
      expect(service).to receive(:log_with_id).with(req_id, /Updated PV to retain/)
      
      result = service.retain_pv(req_id, client, volume_id)
      expect(result).to eq(pv)
      expect(pv["spec"]["persistentVolumeReclaimPolicy"]).to eq("Retain")
    end

    it "does not update PV when reclaim policy is already Retain" do
      pv = {
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Retain"
        }
      }
      
      allow(client).to receive(:find_pv_by_volume_id).with(volume_id).and_return(pv)
      expect(service).to receive(:log_with_id).with(req_id, /Found PV with volume_id/)
      expect(client).not_to receive(:update_pv)
      expect(service).not_to receive(:log_with_id).with(req_id, /Updated PV to retain/)
      
      result = service.retain_pv(req_id, client, volume_id)
      expect(result).to eq(pv)
    end
  end
end

