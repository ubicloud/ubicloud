# frozen_string_literal: true

require "spec_helper"

RSpec.describe Csi::V1::ControllerService do
  let(:service) { described_class.new }

  describe "#log_with_id" do
    it "logs messages with request ID" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#run_cmd" do
    let(:cmd) { ["echo", "test"] }

    it "runs command without request ID" do
      allow(Open3).to receive(:capture2e).with(*cmd).and_return(["output", instance_double(Process::Status)])
      expect { service.run_cmd(*cmd) }.not_to raise_error
    end

    it "runs command with request ID and logs" do
      allow(Open3).to receive(:capture2e).with(*cmd).and_return(["output", instance_double(Process::Status)])
      expect(service).to receive(:log_with_id).with("test-id", /Running command/)
      service.run_cmd(*cmd, req_id: "test-id")
    end

    it "does not log when req_id is nil" do
      allow(Open3).to receive(:capture2e).with(*cmd).and_return(["output", instance_double(Process::Status)])
      expect(service).not_to receive(:log_with_id)
      service.run_cmd(*cmd, req_id: nil)
    end
  end

  describe "#controller_get_capabilities" do
    let(:request) { Csi::V1::ControllerGetCapabilitiesRequest.new }
    let(:call) { instance_double(GRPC::ActiveCall) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "returns controller capabilities" do
      response = service.controller_get_capabilities(request, call)
      expect(response.capabilities.length).to eq(1)
      expect(response.capabilities.first.rpc.type).to eq(:CREATE_DELETE_VOLUME)
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /controller_get_capabilities request/)
      expect(service).to receive(:log_with_id).with("test-uuid", /controller_get_capabilities response/)
      service.controller_get_capabilities(request, call)
    end

    it "raises InvalidArgument when request is nil" do
      expect { service.controller_get_capabilities(nil, call) }.to raise_error(GRPC::InvalidArgument, /Request cannot be nil/)
    end
  end

  describe "#select_worker_topology" do
    let(:topology_kc) do
      Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "kc-worker-1"})
    end

    let(:topology_worker) do
      Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "worker-1"})
    end

    let(:topology_worker2) do
      Csi::V1::Topology.new(segments: {"kubernetes.io/hostname" => "worker-2"})
    end

    context "when preferred topology has suitable worker" do
      let(:request) do
        Csi::V1::CreateVolumeRequest.new(
          accessibility_requirements: {
            preferred: [topology_worker, topology_kc],
            requisite: [topology_kc]
          }
        )
      end

      it "selects from preferred topology" do
        result = service.select_worker_topology(request)
        expect(result.segments["kubernetes.io/hostname"]).to eq("worker-1")
      end
    end

    context "when only requisite topology has suitable worker" do
      let(:request) do
        Csi::V1::CreateVolumeRequest.new(
          accessibility_requirements: {
            preferred: [topology_kc],
            requisite: [topology_worker2, topology_kc]
          }
        )
      end

      it "selects from requisite topology" do
        result = service.select_worker_topology(request)
        expect(result.segments["kubernetes.io/hostname"]).to eq("worker-2")
      end
    end

    context "when no suitable worker topology found" do
      let(:request) do
        Csi::V1::CreateVolumeRequest.new(
          accessibility_requirements: {
            preferred: [topology_kc],
            requisite: [topology_kc]
          }
        )
      end

      it "raises FailedPrecondition" do
        expect { service.select_worker_topology(request) }.to raise_error(GRPC::FailedPrecondition, /No suitable worker node topology found/)
      end
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
    let(:valid_request) do
      Csi::V1::CreateVolumeRequest.new(
        name: "test-volume",
        capacity_range: {required_bytes: 1024 * 1024 * 1024}, # 1GB
        volume_capabilities: [volume_capability],
        accessibility_requirements: {
          requisite: [topology],
          preferred: [topology]
        },
        parameters: {"type" => "ssd"}
      )
    end

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid", "vol-test-uuid")
    end

    context "with valid request" do
      it "creates a new volume" do
        response = service.create_volume(valid_request, call)
        expect(response.volume.volume_id).to eq("vol-vol-test-uuid")
        expect(response.volume.capacity_bytes).to eq(1024 * 1024 * 1024)
        expect(response.volume.volume_context["size_bytes"]).to eq("1073741824")
        expect(response.volume.accessible_topology.first.segments["kubernetes.io/hostname"]).to eq("worker-1")
      end

      it "stores volume in volume store" do
        service.create_volume(valid_request, call)
        volume_store = service.instance_variable_get(:@volume_store)
        expect(volume_store["test-volume"]).to include(
          volume_id: "vol-vol-test-uuid",
          name: "test-volume",
          capacity_bytes: 1024 * 1024 * 1024
        )
      end

      it "logs request and response" do
        expect(service).to receive(:log_with_id).with("test-uuid", /create_volume request/)
        expect(service).to receive(:log_with_id).with("test-uuid", /create_volume response/)
        service.create_volume(valid_request, call)
      end
    end

    context "when volume already exists with same parameters" do
      before do
        service.create_volume(valid_request, call)
        allow(SecureRandom).to receive(:uuid).and_return("test-uuid-2")
      end

      it "returns existing volume" do
        response = service.create_volume(valid_request, call)
        expect(response.volume.volume_id).to eq("vol-vol-test-uuid")
      end

      it "logs existing volume response" do
        expect(service).to receive(:log_with_id).with("test-uuid-2", /create_volume request/).ordered
        expect(service).to receive(:log_with_id).with("test-uuid-2", /create_volume response/).ordered
        service.create_volume(valid_request, call)
      end
    end

    context "when volume exists with different topology" do
      let(:different_topology_request) do
        Csi::V1::CreateVolumeRequest.new(
          name: "test-volume",
          capacity_range: {required_bytes: 1024 * 1024 * 1024},
          volume_capabilities: [volume_capability],
          accessibility_requirements: {
            requisite: [{segments: {"kubernetes.io/hostname" => "worker-2"}}]
          },
          parameters: {"type" => "ssd"}
        )
      end

      before do
        service.create_volume(valid_request, call)
      end

      it "raises FailedPrecondition" do
        expect { service.create_volume(different_topology_request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Existing volume has incompatible topology")
      end
    end

    context "when volume exists with different size" do
      let(:different_size_request) do
        Csi::V1::CreateVolumeRequest.new(
          name: "test-volume",
          capacity_range: {required_bytes: 2 * 1024 * 1024 * 1024}, # 2GB
          volume_capabilities: [volume_capability],
          accessibility_requirements: {
            requisite: [topology]
          },
          parameters: {"type" => "ssd"}
        )
      end

      before do
        service.create_volume(valid_request, call)
      end

      it "raises FailedPrecondition" do
        expect { service.create_volume(different_size_request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different size exists")
      end
    end

    context "when volume exists with different parameters" do
      let(:different_params_request) do
        Csi::V1::CreateVolumeRequest.new(
          name: "test-volume",
          capacity_range: {required_bytes: 1024 * 1024 * 1024},
          volume_capabilities: [volume_capability],
          accessibility_requirements: {
            requisite: [topology]
          },
          parameters: {"type" => "hdd"}
        )
      end

      before do
        service.create_volume(valid_request, call)
      end

      it "raises FailedPrecondition" do
        expect { service.create_volume(different_params_request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different parameters exists")
      end
    end

    context "when volume exists with different capabilities" do
      let(:different_capabilities_request) do
        Csi::V1::CreateVolumeRequest.new(
          name: "test-volume",
          capacity_range: {required_bytes: 1024 * 1024 * 1024},
          volume_capabilities: [{
            block: {},
            access_mode: {mode: :MULTI_NODE_READER_ONLY}
          }],
          accessibility_requirements: {
            requisite: [topology]
          },
          parameters: {"type" => "ssd"}
        )
      end

      before do
        service.create_volume(valid_request, call)
      end

      it "raises FailedPrecondition" do
        expect { service.create_volume(different_capabilities_request, call) }.to raise_error(GRPC::FailedPrecondition, "9:Volume with same name but different capabilities exists")
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

      it "raises InvalidArgument when name is empty" do
        request = Csi::V1::CreateVolumeRequest.new(name: "")
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

      it "raises InvalidArgument when required_bytes is negative" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: -1}
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Required bytes must be positive")
      end

      it "raises OUT_OF_RANGE when volume size exceeds maximum" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 3 * 1024 * 1024 * 1024} # 3GB > 2GB max
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume size exceeds maximum allowed size of 2GB")
      end

      it "raises InvalidArgument when volume_capabilities is nil" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 1024},
          volume_capabilities: nil
        )
        expect { service.create_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume capabilities are required")
      end

      it "raises InvalidArgument when volume_capabilities is empty" do
        request = Csi::V1::CreateVolumeRequest.new(
          name: "test",
          capacity_range: {required_bytes: 1024},
          volume_capabilities: []
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
    let(:kubernetes_client) { instance_double(Csi::KubernetesClient) }
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
      allow(Csi::KubernetesClient).to receive(:new).with(req_id: "test-uuid").and_return(kubernetes_client)
    end

    context "with valid request and volume in store" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-123") }

      before do
        # Add volume to store
        service.instance_variable_get(:@volume_store)["test-volume"] = {
          volume_id: "vol-123",
          name: "test-volume"
        }

        allow(kubernetes_client).to receive(:get_pv).with("test-volume").and_return({
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
        })
        allow(kubernetes_client).to receive(:extract_node_from_pv).and_return("worker-1")
        allow(kubernetes_client).to receive(:get_node_ip).with("worker-1").and_return("10.0.0.1")
        allow(service).to receive(:run_cmd).and_return(["", success_status])
      end

      it "deletes volume successfully" do
        response = service.delete_volume(request, call)
        expect(response).to be_a(Csi::V1::DeleteVolumeResponse)
        expect(service.instance_variable_get(:@volume_store)["test-volume"]).to be_nil
      end

      it "logs request and response" do
        expect(service).to receive(:log_with_id).with("test-uuid", /delete_volume request/)
        expect(service).to receive(:log_with_id).with("test-uuid", /delete_volume response/)
        service.delete_volume(request, call)
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

    context "with volume not in store but found via kubernetes" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-456") }

      before do
        allow(kubernetes_client).to receive(:find_pv_by_volume_id).with("vol-456").and_return({
          "metadata" => {"name" => "pv-456"},
          "spec" => {
            "nodeAffinity" => {
              "required" => {
                "nodeSelectorTerms" => [{
                  "matchExpressions" => [{
                    "values" => ["worker-2"]
                  }]
                }]
              }
            }
          }
        })
        allow(kubernetes_client).to receive(:extract_node_from_pv).and_return("worker-2")
        allow(kubernetes_client).to receive(:get_node_ip).with("worker-2").and_return("10.0.0.2")
        allow(service).to receive(:run_cmd).and_return(["", success_status])
      end

      it "deletes volume successfully" do
        response = service.delete_volume(request, call)
        expect(response).to be_a(Csi::V1::DeleteVolumeResponse)
      end
    end

    context "when SSH command fails" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-789") }

      before do
        service.instance_variable_get(:@volume_store)["test-volume"] = {
          volume_id: "vol-789",
          name: "test-volume"
        }

        allow(kubernetes_client).to receive_messages(
          get_pv: {},
          extract_node_from_pv: "worker-1",
          get_node_ip: "10.0.0.1"
        )
        allow(service).to receive(:run_cmd).and_return(["Permission denied", failure_status])
      end

      it "raises Internal error" do
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

      it "raises InvalidArgument when volume_id is empty" do
        request = Csi::V1::DeleteVolumeRequest.new(volume_id: "")
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::InvalidArgument, "3:Volume ID is required")
      end
    end

    context "when unexpected error occurs" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "vol-error") }

      before do
        allow(service).to receive(:log_with_id)
        allow(kubernetes_client).to receive(:find_pv_by_volume_id).and_raise(StandardError, "Unexpected error")
      end

      it "raises Internal error and logs the exception" do
        expect { service.delete_volume(request, call) }.to raise_error(GRPC::Internal, "13:DeleteVolume error: Unexpected error")
      end
    end

    context "when GRPC::InvalidArgument is raised" do
      let(:request) { Csi::V1::DeleteVolumeRequest.new(volume_id: "") }

      before do
        allow(service).to receive(:log_with_id)
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
