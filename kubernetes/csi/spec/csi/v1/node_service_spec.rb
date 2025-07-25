# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::V1::NodeService do
  let(:req_id) { "test-req-id" }
  let(:client) { Csi::KubernetesClient.new(logger: Logger.new($stdout), req_id:) }
  let(:service) { described_class.new(logger: Logger.new($stdout), node_id: "test-node") }

  before do
    allow(Dir).to receive(:exist?).and_return(true)
  end

  describe "directory creation logic" do
    it "creates backing directory when doesn't exist" do
      expect(Dir).to receive(:exist?).with("/var/lib/ubicsi").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/lib/ubicsi")
      described_class.new(logger: Logger.new($stdout), node_id: "test-node")
    end
  end

  describe "#node_get_capabilities" do
    let(:call) { instance_double(GRPC::ActiveCall) }
    let(:request) { Csi::V1::NodeGetCapabilitiesRequest.new }

    before do
      expect(SecureRandom).to receive(:uuid).and_return("test-uuid").at_least(:once)
      expect(service).to receive(:log_with_id).at_least(:once)
    end

    it "returns node capabilities with STAGE_UNSTAGE_VOLUME" do
      response = service.node_get_capabilities(request, call)

      expect(response).to be_a(Csi::V1::NodeGetCapabilitiesResponse)
      expect(response.capabilities.length).to eq(1)
      expect(response.capabilities.first.rpc.type).to eq(:STAGE_UNSTAGE_VOLUME)
    end
  end

  describe "#node_get_info" do
    let(:call) { instance_double(GRPC::ActiveCall) }
    let(:request) { Csi::V1::NodeGetInfoRequest.new }

    before do
      expect(SecureRandom).to receive(:uuid).and_return("test-uuid").at_least(:once)
      expect(service).to receive(:log_with_id).at_least(:once)
    end

    it "returns node information" do
      response = service.node_get_info(request, call)

      expect(response).to be_a(Csi::V1::NodeGetInfoResponse)
      expect(response.node_id).to eq("test-node")
      expect(response.max_volumes_per_node).to eq(8)
      expect(response.accessible_topology.segments["kubernetes.io/hostname"]).to eq("test-node")
    end
  end

  describe "helper methods" do
    describe ".backing_file_path" do
      it "returns correct backing file path" do
        expect(described_class.backing_file_path("vol-123")).to eq("/var/lib/ubicsi/vol-123.img")
      end
    end

    describe "#run_cmd" do
      it "executes command and returns output and status" do
        expect(Open3).to receive(:capture2e).with("echo", "test").and_return(["output", 0])

        output, status = service.run_cmd("echo", "test", req_id: "req-id")
        expect(output).to eq("output")
        expect(status).to eq(0)
      end
    end

    describe "#run_cmd_output" do
      it "extracts output from run_cmd result" do
        expect(service).to receive(:run_cmd).with("echo", "test", req_id: "req-id").and_return(["extracted_output", 0])

        result = service.run_cmd_output("echo", "test", req_id: "req-id")
        expect(result).to eq("extracted_output")
      end
    end

    describe "#is_mounted?" do
      it "returns true when path is mounted" do
        expect(service).to receive(:run_cmd).with("mountpoint", "-q", "/mnt/test", req_id: "req-id").and_return(["", 0])
        expect(service.is_mounted?("/mnt/test", req_id: "req-id")).to be true
      end

      it "returns false when path is not mounted" do
        expect(service).to receive(:run_cmd).with("mountpoint", "-q", "/mnt/test", req_id: "req-id").and_return(["", 1])
        expect(service.is_mounted?("/mnt/test", req_id: "req-id")).to be false
      end
    end

    describe "#find_loop_device" do
      it "returns loop device when found" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["/dev/loop0: [2049]:123456 (/path/to/file)", true])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to eq("/dev/loop0")
      end

      it "returns nil when not found" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["", true])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to be_nil
      end

      it "returns nil when command fails" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["some output", false])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to be_nil
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
        pvc = {"metadata" => {"annotations" => {}}}
        expect(service.pvc_needs_migration?(pvc)).to be false
      end

      it "returns false when metadata is missing" do
        pvc = {}
        expect(service.pvc_needs_migration?(pvc)).to be false
      end
    end
  end

  # Additional tests to cover uncovered branches systematically
  describe "branch coverage improvements" do
    describe "#find_loop_device" do
      it "returns nil when command fails" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["", false])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to be_nil
      end

      it "returns nil when output is empty" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["", true])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to be_nil
      end

      it "returns nil when loop device doesn't start with /dev/loop" do
        expect(service).to receive(:run_cmd).with("losetup", "-j", "/path/to/file", req_id: "req-id").and_return(["invalid: output", true])
        expect(service.find_loop_device("/path/to/file", req_id: "req-id")).to be_nil
      end
    end

    describe "#fetch_and_migrate_pvc" do
      let(:req_id) { "test-req-id" }
      let(:client) { instance_double(Csi::KubernetesClient) }
      let(:req) do
        Csi::V1::NodeStageVolumeRequest.new(
          volume_context: {
            "csi.storage.k8s.io/pvc/namespace" => "default",
            "csi.storage.k8s.io/pvc/name" => "test-pvc"
          }
        )
      end
      let(:pvc) { {"metadata" => {"annotations" => {}}} }

      it "returns PVC without migration when not needed" do
        expect(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        expect(service).to receive(:pvc_needs_migration?).with(pvc).and_return(false)

        result = service.fetch_and_migrate_pvc(req_id, client, req)
        expect(result).to eq(pvc)
      end

      it "migrates PVC data when migration is needed" do
        pvc_with_migration = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "old-pv"}}}
        expect(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc_with_migration)
        expect(service).to receive(:pvc_needs_migration?).with(pvc_with_migration).and_return(true)
        expect(service).to receive(:migrate_pvc_data).with(req_id, client, pvc_with_migration, req)

        result = service.fetch_and_migrate_pvc(req_id, client, req)
        expect(result).to eq(pvc_with_migration)
      end

      it "handles CopyNotFinishedError" do
        expect(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        expect(service).to receive(:pvc_needs_migration?).with(pvc).and_return(true)
        expect(service).to receive(:migrate_pvc_data).and_raise(CopyNotFinishedError, "Copy in progress")

        expect { service.fetch_and_migrate_pvc(req_id, client, req) }.to raise_error(GRPC::Internal, "13:Copy in progress")
      end

      it "handles unexpected errors" do
        expect(client).to receive(:get_pvc).with("default", "test-pvc").and_return(pvc)
        expect(service).to receive(:pvc_needs_migration?).with(pvc).and_return(true)
        expect(service).to receive(:migrate_pvc_data).and_raise(StandardError, "Unexpected error")

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
    let(:pvc) { {"metadata" => {"annotations" => {}}} }
    let(:req) do
      Csi::V1::NodeStageVolumeRequest.new(
        volume_id: volume_id,
        staging_target_path: staging_path,
        volume_context: {"size_bytes" => size_bytes.to_s},
        volume_capability: Csi::V1::VolumeCapability.new(
          mount: Csi::V1::VolumeCapability::MountVolume.new(fs_type: "ext4")
        )
      )
    end

    before do
      expect(service).to receive(:log_with_id).at_least(:once)
      expect(described_class).to receive(:backing_file_path).with(volume_id).and_return(backing_file).at_least(:once)
      # Keep these as allow since they're not used in every test
      allow(service).to receive_messages(
        is_mounted?: false,
        is_copied_pvc?: false,
        find_loop_device: nil
      )
      allow(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["/dev/loop0", true])
      allow(service).to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id).and_return(["", true])
      allow(Dir).to receive(:exist?).with(staging_path).and_return(false)
      allow(FileUtils).to receive(:mkdir_p)
      allow(service).to receive(:run_cmd).with("mount", "/dev/loop0", staging_path, req_id: req_id).and_return(["", true])
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
        expect(File).to receive(:exist?).with(backing_file).and_return(false)
        expect(service).to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["Error message", false])

        expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::ResourceExhausted, /Failed to allocate backing file/)
      end

      it "handles punch hole failure" do
        expect(File).to receive(:exist?).with(backing_file).and_return(false)
        expect(service).to receive(:run_cmd).with("fallocate", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["", true])
        expect(service).to receive(:run_cmd).with("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file, req_id: req_id).and_return(["Punch hole error", false])

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
        expect(service).to receive(:find_loop_device).and_return("/dev/loop1")
        expect(service).to receive(:run_cmd).with("mount", "/dev/loop1", staging_path, req_id: req_id).and_return(["", true])

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
        allow(service).to receive(:is_copied_pvc?).and_return(true)
        expect(service).not_to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id)

        service.perform_node_stage_volume(req_id, pvc, req, nil)
      end

      it "runs nothing when requested storage is already mounted and needs no mkfs" do
        expect(service).to receive_messages(
          find_loop_device: "/dev/loop0",
          is_mounted?: true
        )

        service.perform_node_stage_volume(req_id, pvc, req, nil)
      end

      it "handles mkfs failure" do
        allow(service).to receive_messages(
          find_loop_device: nil,  # New loop device
          is_copied_pvc?: false,
          is_mounted?: false
        )
        expect(service).to receive(:run_cmd).with("losetup", "--find", "--show", backing_file, req_id: req_id).and_return(["/dev/loop0", true])
        expect(service).to receive(:run_cmd).with("mkfs.ext4", "/dev/loop0", req_id: req_id).and_return(["mkfs error", false])

        expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to format device/)
      end

      it "handles mount failure" do
        allow(service).to receive_messages(
          find_loop_device: "/dev/loop0",
          is_copied_pvc?: false,
          is_mounted?: false
        )
        expect(FileUtils).to receive(:mkdir_p)
        expect(service).to receive(:run_cmd).with("mount", "/dev/loop0", staging_path, req_id: req_id).and_return(["mount error", false])

        expect { service.perform_node_stage_volume(req_id, pvc, req, nil) }.to raise_error(GRPC::Internal, /Failed to mount/)
      end

      it "handles general exceptions" do
        expect(service).to receive(:find_loop_device).and_raise(StandardError, "Unexpected error")

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
        volume_context: {"size_bytes" => "1073741824"}
      )
    end
    let(:pvc) { {"metadata" => {"annotations" => {}}} }
    let(:response) { Csi::V1::NodeStageVolumeResponse.new }

    it "stages a volume successfully" do
      allow(service).to receive(:log_with_id)
      allow(Csi::KubernetesClient).to receive(:new).and_return(Csi::KubernetesClient)
      allow(service).to receive_messages(
        fetch_and_migrate_pvc: pvc,
        perform_node_stage_volume: response,
        roll_back_reclaim_policy: nil,
        remove_old_pv_annotation: nil
      )

      result = service.node_stage_volume(req, nil)
      expect(result).to eq(response)
    end
  end

  describe "#remove_old_pv_annotation" do
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
    let(:req) { instance_double(Csi::V1::NodeStageVolumeRequest) }

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

  describe "#is_copied_pvc?" do
    it "returns true when PVC needs migration" do
      pvc = {
        "metadata" => {
          "annotations" => {
            "csi.ubicloud.com/old-pv-name" => "old-pv-123"
          }
        }
      }

      expect(service.is_copied_pvc?(pvc)).to be true
    end

    it "returns false when PVC does not need migration" do
      pvc = {
        "metadata" => {
          "annotations" => {}
        }
      }

      expect(service.is_copied_pvc?(pvc)).to be false
    end
  end

  describe "#migrate_pvc_data" do
    let(:req) { Csi::V1::NodeStageVolumeRequest.new(volume_id: "vol-new-123") }
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
      expect(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", "copy_old-pv-123", req_id:).and_return("NotStarted")
      allow(service).to receive(:run_cmd_output).with("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "run", any_args, req_id:)

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
    let(:req) { Csi::V1::NodeUnstageVolumeRequest.new(volume_id: "vol-test-123", staging_target_path: "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount") }
    let(:response) { Csi::V1::NodeUnstageVolumeResponse.new }

    before do
      allow(SecureRandom).to receive(:uuid).and_return(req_id)
      allow(service).to receive(:log_with_id)
      allow(Csi::KubernetesClient).to receive(:new).and_return(client)
    end

    it "unstages a volume successfully when node is schedulable" do
      allow(client).to receive(:node_schedulable?).with(service.node_id).and_return(true)
      allow(service).to receive(:is_mounted?).with(req.staging_target_path, req_id: "test-req-id").and_return(true)

      result = service.node_unstage_volume(req, nil)
      expect(result).to eq(response)
    end

    it "prepares data migration when node is not schedulable" do
      allow(client).to receive(:node_schedulable?).with(service.node_id).and_return(false)
      expect(service).to receive(:prepare_data_migration).with(client, "test-req-id", "vol-test-123")
      allow(service).to receive(:is_mounted?).with(req.staging_target_path, req_id:).and_return(true)

      result = service.node_unstage_volume(req, nil)
      expect(result).to eq(response)
    end

    it "handles errors and raises GRPC::Internal" do
      allow(client).to receive(:node_schedulable?).with(service.node_id).and_raise(StandardError, "Test error")

      expect { service.node_unstage_volume(req, nil) }.to raise_error(GRPC::Internal, "13:NodeUnstageVolume error: StandardError - Test error")
    end

    it "handles umount failure when staging path is mounted" do
      expect(client).to receive(:node_schedulable?).with(service.node_id).and_return(true)
      expect(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id:).and_return(true)
      expect(service).to receive(:run_cmd).with("umount", "-q", "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id:).and_return(["umount: device is busy", false])

      expect { service.node_unstage_volume(req, nil) }.to raise_error(GRPC::Internal, "13:Failed to unmount /var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount: umount: device is busy")
    end

    it "skips umount when staging path is not mounted" do
      expect(client).to receive(:node_schedulable?).with(service.node_id).and_return(true)
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id:).and_return(false)

      result = service.node_unstage_volume(req, nil)
      expect(result).to eq(response)
    end

    it "handles GRPC::BadStatus exceptions" do
      expect(client).to receive(:node_schedulable?).with(service.node_id).and_return(true)
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id:).and_raise(GRPC::InvalidArgument, "Invalid argument")

      expect { service.node_unstage_volume(req, nil) }.to raise_error(GRPC::InvalidArgument, "3:Invalid argument")
    end

    it "handles general exceptions and converts to GRPC::Internal" do
      expect(client).to receive(:node_schedulable?).with(service.node_id).and_return(true)
      allow(service).to receive(:is_mounted?).with("/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount", req_id:).and_raise(StandardError, "Unexpected error")
      expect { service.node_unstage_volume(req, nil) }.to raise_error(GRPC::Internal, "13:NodeUnstageVolume error: StandardError - Unexpected error")
    end
  end

  describe "#prepare_data_migration" do
    let(:volume_id) { "vol-test-123" }
    let(:pv) { {"metadata" => {"name" => "pv-123"}} }

    it "retains PV and recreates PVC" do
      expect(service).to receive(:log_with_id).with(req_id, /Retaining pv with volume_id/)
      expect(service).to receive(:retain_pv).with(req_id, client, volume_id).and_return(pv)
      expect(service).to receive(:log_with_id).with(req_id, /Recreating pvc with volume_id/)
      expect(service).to receive(:recreate_pvc).with(req_id, client, pv)

      service.prepare_data_migration(client, req_id, volume_id)
    end
  end

  describe "#retain_pv" do
    let(:volume_id) { "vol-test-123" }

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

  describe "#node_unpublish_volume" do
    let(:target_path) { "/var/lib/kubelet/pods/pod-123/volumes/kubernetes.io~csi/vol-test-123/mount" }
    let(:req_id) { "test-req-id" }
    let(:req) do
      Csi::V1::NodeUnpublishVolumeRequest.new(
        volume_id: "vol-test-123",
        target_path: target_path
      )
    end

    before do
      allow(service).to receive(:log_with_id)
      allow(SecureRandom).to receive(:uuid).and_return(req_id)
    end

    it "unpublishes a mounted volume successfully" do
      allow(service).to receive(:is_mounted?).with(target_path, req_id:).and_return(true)
      allow(service).to receive(:run_cmd).with("umount", "-q", target_path, req_id:).and_return(["", true])

      result = service.node_unpublish_volume(req, nil)

      expect(result).to be_a(Csi::V1::NodeUnpublishVolumeResponse)
    end

    it "skips umount when target path is not mounted" do
      allow(service).to receive(:is_mounted?).with(target_path, req_id:).and_return(false)
      expect(service).to receive(:log_with_id).with(req_id, /is not mounted, skipping umount/)

      result = service.node_unpublish_volume(req, nil)

      expect(result).to be_a(Csi::V1::NodeUnpublishVolumeResponse)
    end

    it "handles umount failure" do
      allow(service).to receive(:is_mounted?).with(target_path, req_id:).and_return(true)
      allow(service).to receive(:run_cmd).with("umount", "-q", target_path, req_id:).and_return(["umount error", false])

      expect(service).to receive(:log_with_id).with(req_id, /failed to umount device/)
      expect { service.node_unpublish_volume(req, nil) }.to raise_error(GRPC::Internal, /Failed to unmount/)
    end

    it "handles GRPC::BadStatus exceptions" do
      allow(service).to receive(:is_mounted?).with(target_path, req_id:).and_raise(GRPC::InvalidArgument, "Invalid argument")

      expect(service).to receive(:log_with_id).with(req_id, /gRPC error in node_unpublish_volume/)
      expect { service.node_unpublish_volume(req, nil) }.to raise_error(GRPC::InvalidArgument, "3:Invalid argument")
    end

    it "handles general exceptions and converts to GRPC::Internal" do
      allow(service).to receive(:is_mounted?).with(target_path, req_id:).and_raise(StandardError, "Unexpected error")

      expect(service).to receive(:log_with_id).with(req_id, /Internal error in node_unpublish_volume/)
      expect { service.node_unpublish_volume(req, nil) }.to raise_error(GRPC::Internal, /NodeUnpublishVolume error/)
    end
  end

  describe "#node_publish_volume" do
    let(:staging_path) { "/var/lib/kubelet/plugins/kubernetes.io/csi/pv/vol-test-123/globalmount" }
    let(:target_path) { "/var/lib/kubelet/pods/pod-123/volumes/kubernetes.io~csi/vol-test-123/mount" }
    let(:req) do
      Csi::V1::NodePublishVolumeRequest.new(
        volume_id: "vol-test-123",
        staging_target_path: staging_path,
        target_path: target_path,
        volume_capability: Csi::V1::VolumeCapability.new(
          mount: Csi::V1::VolumeCapability::MountVolume.new(fs_type: "ext4")
        )
      )
    end

    before do
      allow(service).to receive(:log_with_id)
      allow(SecureRandom).to receive(:uuid).and_return("test-req-id")
    end

    it "publishes a volume successfully" do
      allow(FileUtils).to receive(:mkdir_p).with(target_path)
      allow(service).to receive(:run_cmd).with("mount", "--bind", staging_path, target_path, req_id: "test-req-id").and_return(["", true])

      result = service.node_publish_volume(req, nil)

      expect(result).to be_a(Csi::V1::NodePublishVolumeResponse)
    end

    it "handles bind mount failure" do
      allow(FileUtils).to receive(:mkdir_p).with(target_path)
      allow(service).to receive(:run_cmd).with("mount", "--bind", staging_path, target_path, req_id: "test-req-id").and_return(["mount error", false])

      expect(service).to receive(:log_with_id).with("test-req-id", /failed to bind mount device/)
      expect { service.node_publish_volume(req, nil) }.to raise_error(GRPC::Internal, /Failed to bind mount/)
    end

    it "handles GRPC::BadStatus exceptions" do
      allow(FileUtils).to receive(:mkdir_p).with(target_path).and_raise(GRPC::InvalidArgument, "Invalid argument")

      expect(service).to receive(:log_with_id).with("test-req-id", /gRPC error in node_publish_volume/)
      expect { service.node_publish_volume(req, nil) }.to raise_error(GRPC::InvalidArgument, "3:Invalid argument")
    end

    it "handles general exceptions and converts to GRPC::Internal" do
      allow(FileUtils).to receive(:mkdir_p).with(target_path).and_raise(StandardError, "Unexpected error")

      expect(service).to receive(:log_with_id).with("test-req-id", /Internal error in node_publish_volume/)
      expect { service.node_publish_volume(req, nil) }.to raise_error(GRPC::Internal, /NodePublishVolume error/)
    end
  end

  describe "#recreate_pvc" do
    let(:pv) do
      {
        "metadata" => {
          "name" => "pv-123",
          "annotations" => {}
        },
        "spec" => {
          "claimRef" => {
            "namespace" => "default",
            "name" => "pvc-123"
          }
        }
      }
    end
    let(:pvc) do
      {
        "metadata" => {
          "name" => "pvc-123",
          "namespace" => "default",
          "resourceVersion" => "12345",
          "uid" => "uid-123",
          "creationTimestamp" => "2023-01-01T00:00:00Z"
        },
        "spec" => {
          "volumeName" => "pv-123"
        },
        "status" => {}
      }
    end

    before do
      allow(service).to receive(:log_with_id)
      allow(service).to receive(:trim_pvc).and_return(pvc)
      allow(Base64).to receive(:strict_encode64).and_return("base64_content")
    end

    it "recreates PVC when PVC exists" do
      allow(client).to receive(:get_pvc).with("default", "pvc-123").and_return(pvc)
      expect(client).to receive(:update_pv).with(pv)
      expect(client).to receive(:delete_pvc).with("default", "pvc-123")
      expect(client).to receive(:create_pvc).with(pvc)

      service.recreate_pvc(req_id, client, pv)

      expect(pv["metadata"]["annotations"]["csi.ubicloud.com/old-pvc-object"]).to eq("base64_content")
    end

    it "recreates PVC from annotation when PVC not found" do
      old_pvc_data = "different_base64_content"  # Different from "base64_content"
      pv["metadata"]["annotations"]["csi.ubicloud.com/old-pvc-object"] = old_pvc_data

      allow(client).to receive(:get_pvc).with("default", "pvc-123").and_raise(ObjectNotFoundError.new("PVC not found"))
      allow(Base64).to receive(:decode64).with(old_pvc_data).and_return("decoded_yaml")
      allow(YAML).to receive(:load).with("decoded_yaml").and_return(pvc)

      # Since the annotation content is different from base64_content, it should update
      expect(client).to receive(:update_pv).with(pv)
      expect(client).to receive(:delete_pvc).with("default", "pvc-123")
      expect(client).to receive(:create_pvc).with(pvc)

      service.recreate_pvc(req_id, client, pv)
    end

    it "raises error when PVC not found and no annotation" do
      pv["metadata"]["annotations"]["csi.ubicloud.com/old-pvc-object"] = ""

      error = ObjectNotFoundError.new("PVC not found")
      allow(client).to receive(:get_pvc).with("default", "pvc-123").and_raise(error)

      expect { service.recreate_pvc(req_id, client, pv) }.to raise_error(ObjectNotFoundError)
    end

    it "skips PV update when annotation already matches" do
      pv["metadata"]["annotations"]["csi.ubicloud.com/old-pvc-object"] = "base64_content"

      allow(client).to receive(:get_pvc).with("default", "pvc-123").and_return(pvc)
      expect(client).not_to receive(:update_pv)
      expect(client).to receive(:delete_pvc).with("default", "pvc-123")
      expect(client).to receive(:create_pvc).with(pvc)

      service.recreate_pvc(req_id, client, pv)
    end
  end

  describe "#trim_pvc" do
    let(:pv_name) { "pv-123" }
    let(:pvc) do
      {
        "metadata" => {
          "name" => "pvc-123",
          "namespace" => "default",
          "annotations" => {
            "existing-annotation" => "value"
          },
          "resourceVersion" => "12345",
          "uid" => "uid-123",
          "creationTimestamp" => "2023-01-01T00:00:00Z"
        },
        "spec" => {
          "volumeName" => "old-pv-name"
        },
        "status" => {
          "phase" => "Bound"
        }
      }
    end

    it "trims PVC metadata and spec for recreation" do
      result = service.trim_pvc(pvc, pv_name)

      # Should set the old PV name annotation
      expect(result["metadata"]["annotations"]).to eq({"csi.ubicloud.com/old-pv-name" => pv_name})

      # Should remove metadata fields
      expect(result["metadata"]).not_to have_key("resourceVersion")
      expect(result["metadata"]).not_to have_key("uid")
      expect(result["metadata"]).not_to have_key("creationTimestamp")

      # Should remove volumeName from spec
      expect(result["spec"]).not_to have_key("volumeName")

      # Should remove status
      expect(result).not_to have_key("status")

      # Should return the same object
      expect(result).to eq(pvc)
    end
  end
end
