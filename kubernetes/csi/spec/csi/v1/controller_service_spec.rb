# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::V1::ControllerService do
  let(:service) { described_class.new(logger: Logger.new($stdout)) }

  describe "#log_with_id" do
    it "logs messages with request ID" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#controller_get_capabilities" do
    let(:request) { Csi::V1::ControllerGetCapabilitiesRequest.new }
    let(:call) { instance_double(GRPC::ActiveCall) }

    it "returns CREATE_DELETE_VOLUME capability" do
      expect(SecureRandom).to receive(:uuid).and_return("test-uuid")
      response = service.controller_get_capabilities(request, call)
      expect(response.capabilities.first.rpc.type).to eq(:CREATE_DELETE_VOLUME)
    end

    it "raises InvalidArgument when request is nil" do
      expect { service.controller_get_capabilities(nil, call) }.to raise_error(GRPC::InvalidArgument, /Request cannot be nil/)
    end
  end

  describe "#select_worker_topology" do
    let(:kc) { Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "kc-worker-1"}) }
    let(:worker1) { Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "worker-1"}) }
    let(:worker2) { Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "worker-2"}) }

    it "selects from preferred topology when suitable worker exists" do
      request = Csi::V1::CreateVolumeRequest.new(
        accessibility_requirements: {
          preferred: [worker1, kc],
          requisite: [kc]
        }
      )
      expect(service.select_worker_topology(request).segments["kubernetes.io/hostname"]).to eq("worker-1")
    end

    it "selects from requisite topology when preferred has no suitable worker" do
      request = Csi::V1::CreateVolumeRequest.new(
        accessibility_requirements: {
          preferred: [kc],
          requisite: [worker2, kc]
        }
      )
      expect(service.select_worker_topology(request).segments["kubernetes.io/hostname"]).to eq("worker-2")
    end

    it "raises FailedPrecondition when no suitable worker found" do
      request = Csi::V1::CreateVolumeRequest.new(
        accessibility_requirements: {
          preferred: [kc],
          requisite: [kc]
        }
      )
      expect { service.select_worker_topology(request) }.to raise_error(GRPC::FailedPrecondition, /No suitable worker node topology found/)
    end
  end

  describe "#create_volume" do
    let(:call) { instance_double(GRPC::ActiveCall) }
    let(:volume_capability) do
      {
        mount: {fs_type: "ext4", mount_flags: []},
        access_mode: {mode: :SINGLE_NODE_WRITER}
      }
    end
    let(:topology) do
      {segments: {"kubernetes.io/hostname" => "worker-1"}}
    end
    let(:base_request_args) do
      {
        name: "test-volume",
        capacity_range: {required_bytes: 1024 * 1024 * 1024}, # 1GB
        volume_capabilities: [volume_capability],
        accessibility_requirements: {
          requisite: [topology],
          preferred: [topology]
        },
        parameters: {"type" => "ssd"}
      }
    end
    let(:valid_request) { Csi::V1::CreateVolumeRequest.new(base_request_args) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid", "vol-test-uuid")
    end

    context "with valid request" do
      it "creates a new volume and stores it in volume store" do
        response = service.create_volume(valid_request, call)

        # Verify response
        expect(response.volume.volume_id).to eq("vol-vol-test-uuid")
        expect(response.volume.capacity_bytes).to eq(1024 * 1024 * 1024)
        expect(response.volume.volume_context["size_bytes"]).to eq("1073741824")
        expect(response.volume.accessible_topology.first.segments["kubernetes.io/hostname"]).to eq("worker-1")

        # Verify volume store
        volume_store = service.instance_variable_get(:@volume_store)
        expect(volume_store["test-volume"]).to include(
          volume_id: "vol-vol-test-uuid",
          name: "test-volume",
          capacity_bytes: 1024 * 1024 * 1024
        )

        # Verify idempotent behavior - calling again returns same volume
        response2 = service.create_volume(valid_request, call)
        expect(response2.volume.volume_id).to eq("vol-vol-test-uuid")
      end
    end

    context "when volume exists with different attributes" do
      before do
        service.create_volume(valid_request, call)
      end

      it "raises FailedPrecondition for incompatible topology" do
        base_request_args[:accessibility_requirements] = {requisite: [{segments: {"kubernetes.io/hostname" => "worker-2"}}]}
        request = Csi::V1::CreateVolumeRequest.new(base_request_args)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Existing volume has incompatible topology")
      end

      it "raises FailedPrecondition for different size" do
        base_request_args[:capacity_range] = {required_bytes: 2 * 1024 * 1024 * 1024} # 2GB
        request = Csi::V1::CreateVolumeRequest.new(base_request_args)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different size exists")
      end

      it "raises FailedPrecondition for different parameters" do
        base_request_args[:parameters] = {"type" => "hdd"}
        request = Csi::V1::CreateVolumeRequest.new(base_request_args)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different parameters exists")
      end

      it "raises FailedPrecondition for different capabilities" do
        base_request_args[:volume_capabilities] = [{block: {}, access_mode: {mode: :MULTI_NODE_READER_ONLY}}]
        request = Csi::V1::CreateVolumeRequest.new(base_request_args)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different capabilities exists")
      end
    end

    context "when validation errors happen" do
      it "raises InvalidArgument when request is nil" do
        expect { service.create_volume(nil, call) }.to raise_error(GRPC::InvalidArgument, "3:Request cannot be nil")
      end

      it "raises InvalidArgument when name is nil" do
        request = Csi::V1::CreateVolumeRequest.new(name: nil)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume name is required")
      end

      it "raises InvalidArgument when capacity_range is nil" do
        request = Csi::V1::CreateVolumeRequest.new(name: "test", capacity_range: nil)
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Capacity range is required")
      end

      it "raises InvalidArgument when required_bytes is zero" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 0}
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Required bytes must be positive")
      end

      it "raises OUT_OF_RANGE when volume size exceeds maximum" do
        ENV.delete("DISK_LIMIT_GB")
        service = described_class.new(logger: Logger.new($stdout))

        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 11 * 1024 * 1024 * 1024} # 11GB > 10GB max
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume size exceeds maximum allowed size of 10GB")
      end

      it "raises OUT_OF_RANGE when volume size exceeds maximum when a dynamic value is set" do
        ENV["DISK_LIMIT_GB"] = "40"
        service = described_class.new(logger: Logger.new($stdout))

        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 45 * 1024 * 1024 * 1024}
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume size exceeds maximum allowed size of 40GB")
      end

      it "raises InvalidArgument when volume_capabilities is nil" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 1024},
          volume_capabilities: nil
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume capabilities are required")
      end

      it "raises InvalidArgument when accessibility_requirements is nil" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 1024},
          volume_capabilities: [volume_capability],
          accessibility_requirements: nil
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Topology requirement is required")
      end

      it "raises InvalidArgument when requisite topology is empty" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 1024},
          volume_capabilities: [volume_capability],
          accessibility_requirements: {requisite: []}
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Topology requirement is required")
      end
    end
  end

  describe "#delete_volume" do
    let(:call) { instance_double(GRPC::ActiveCall) }
    let(:kubernetes_client) { Csi::KubernetesClient.new(req_id: "test-uuid", logger: Logger.new($stdout)) }
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    context "with valid request and volume in store" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-123") }

      before do
        expect(Csi::KubernetesClient).to receive(:new).and_return(kubernetes_client).at_least(:once)
        # Add volume to store
        service.instance_variable_get(:@volume_store)["test-volume"] = {
          volume_id: "vol-123",
          name: "test-volume"
        }

        expect(kubernetes_client).to receive(:get_pv).with("test-volume").and_return({
          "spec" => {
            "nodeAffinity" => {
              "required" => {
                "nodeSelectorTerms" => [{
                  "matchExpressions" => [{
                    "values" => ["worker-1"]
                  }]
                }]
              }
            }
          }
        }).at_least(:once)
        expect(kubernetes_client).to receive(:extract_node_from_pv).and_return("worker-1").at_least(:once)
        expect(kubernetes_client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1").at_least(:once)
      end

      it "runs SSH command to delete backing file" do
        expect(service).to receive(:run_cmd).with(
          "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
          "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", "sudo", "rm", "-f", "/var/lib/ubicsi/vol-123.img",
          req_id: "test-uuid"
        ).and_return(["", success_status])
        service.delete_volume(request, call)
      end
    end

    context "when SSH command fails" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-789") }

      before do
        expect(Csi::KubernetesClient).to receive(:new).and_return(kubernetes_client).at_least(:once)
        service.instance_variable_get(:@volume_store)["test-volume"] = {
          volume_id: "vol-789",
          name: "test-volume"
        }

        expect(kubernetes_client).to receive(:get_pv).and_return({}).at_least(:once)
        expect(kubernetes_client).to receive(:extract_node_from_pv).and_return("worker-1").at_least(:once)
        expect(kubernetes_client).to receive(:get_node_ip).and_return("10.0.0.1").at_least(:once)
        expect(service).to receive(:run_cmd).and_return(["Permission denied", failure_status]).at_least(:once)
      end

      it "raises Internal error" do
        expect(service).to receive(:log_with_id).at_least(:once)
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::Internal, "13:DeleteVolume error: 13:Could not delete the PV's backing file")
      end
    end

    context "when validation errors happen" do
      it "raises InvalidArgument when request is nil" do
        expect { service.delete_volume(nil, call) }.to raise_error(GRPC::InvalidArgument, "3:Request cannot be nil")
      end

      it "raises InvalidArgument when volume_id is nil" do
        request = Csi::V1::DeleteVolumeRequest.new(volume_id: nil)
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume ID is required")
      end
    end

    context "when unexpected error occurs" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-error") }

      before do
        expect(Csi::KubernetesClient).to receive(:new).and_return(kubernetes_client).at_least(:once)
        expect(service).to receive(:log_with_id).at_least(:once)
        expect(kubernetes_client).to receive(:find_pv_by_volume_id).and_raise(StandardError, "Unexpected error").at_least(:once)
      end

      it "raises Internal error and logs the exception" do
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::Internal, "13:DeleteVolume error: Unexpected error")
      end
    end

    context "when GRPC::InvalidArgument is raised" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "") }

      before do
        expect(service).to receive(:log_with_id).at_least(:once)
      end

      it "logs and re-raises the validation error" do
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume ID is required")
      end
    end
  end

  describe "class inheritance" do
    it "inherits from Controller::Service" do
      expect(described_class.superclass).to eq(Csi::V1::Controller::Service)
    end
  end
end
