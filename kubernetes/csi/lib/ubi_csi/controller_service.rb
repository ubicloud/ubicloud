# frozen_string_literal: true

require "grpc"
require "securerandom"
require_relative "../csi_services_pb"
require "logger"
require "json"

module Csi
  module V1
    class ControllerService < Controller::Service
      MAX_VOLUME_SIZE = 2 * 1024 * 1024 * 1024 # 2GB in bytes
      LOGGER = Logger.new($stdout)

      def initialize
        @volume_store = {} # Maps volume name to volume details
        @mutex = Mutex.new
      end

      def log_with_id(id, message)
        LOGGER.info("[req_id=#{id}] #{message}")
      end

      def run_cmd(*cmd, req_id: nil)
        log_with_id(req_id, "Running command: #{cmd}") unless req_id.nil?
        Open3.capture2e(*cmd)
      end

      def controller_get_capabilities(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "controller_get_capabilities request: #{req.inspect}")
        if req.nil?
          raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT)
        end
        resp = ControllerGetCapabilitiesResponse.new(
          capabilities: [
            ControllerServiceCapability.new(
              rpc: ControllerServiceCapability::RPC.new(
                type: ControllerServiceCapability::RPC::Type::CREATE_DELETE_VOLUME
              )
            )
          ]
        )
        log_with_id(req_id, "controller_get_capabilities response: #{resp.inspect}")
        resp
      end

      def select_worker_topology(req)
        preferred = req.accessibility_requirements.preferred
        requisite = req.accessibility_requirements.requisite

        selected = preferred.find { |topo| !topo.segments["kubernetes.io/hostname"].start_with?("kc") }
        selected ||= requisite.find { |topo| !topo.segments["kubernetes.io/hostname"].start_with?("kc") }

        if selected.nil?
          raise GRPC::FailedPrecondition.new("No suitable worker node topology found", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
        end

        selected
      end

      def create_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "create_volume request: #{req.inspect}")
        raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.nil?
        raise GRPC::InvalidArgument.new("Volume name is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.name.nil? || req.name.empty?
        raise GRPC::InvalidArgument.new("Capacity range is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.nil?
        raise GRPC::InvalidArgument.new("Required bytes must be specified", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.required_bytes.nil?
        raise GRPC::InvalidArgument.new("Required bytes must be positive", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.required_bytes <= 0
        raise GRPC::InvalidArgument.new("Volume size exceeds maximum allowed size of 2GB", GRPC::Core::StatusCodes::OUT_OF_RANGE) if req.capacity_range.required_bytes > MAX_VOLUME_SIZE
        raise GRPC::InvalidArgument.new("Volume capabilities are required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_capabilities.nil? || req.volume_capabilities.empty?
        raise GRPC::InvalidArgument.new("Topology requirement is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.accessibility_requirements.nil? || req.accessibility_requirements.requisite.empty?

        resp = nil
        @mutex.synchronize do
          if @volume_store[req.name]
            existing = @volume_store[req.name]
            if req.accessibility_requirements.requisite.first != existing[:accessible_topology]
              raise GRPC::FailedPrecondition.new("Existing volume has incompatible topology", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            if existing[:capacity_bytes] != req.capacity_range.required_bytes
              raise GRPC::FailedPrecondition.new("Volume with same name but different size exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            if existing[:parameters] != req.parameters.to_h
              raise GRPC::FailedPrecondition.new("Volume with same name but different parameters exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            existing_capabilities = existing[:capabilities].sort_by { |cap| cap.to_json }
            new_capabilities = req.volume_capabilities.map(&:to_h).sort_by { |cap| cap.to_json }

            if existing_capabilities != new_capabilities
              raise GRPC::FailedPrecondition.new("Volume with same name but different capabilities exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            resp = CreateVolumeResponse.new(
              volume: Volume.new(
                volume_id: existing[:volume_id],
                capacity_bytes: req.capacity_range.required_bytes,
                volume_context: req.parameters.to_h.merge("size_bytes" => req.capacity_range.required_bytes.to_s),
                accessible_topology: [req.accessibility_requirements.requisite.first]
              )
            )
            log_with_id(req_id, "create_volume response (existing): #{resp.inspect}")
            return resp
          end

          selected_topology = select_worker_topology(req)
          volume_id = "vol-#{SecureRandom.uuid}"
          @volume_store[req.name] = {
            volume_id: volume_id,
            name: req.name,
            accessible_topology: selected_topology,
            capacity_bytes: req.capacity_range.required_bytes,
            parameters: req.parameters.to_h,
            capabilities: req.volume_capabilities.map(&:to_h)
          }

          resp = CreateVolumeResponse.new(
            volume: Volume.new(
              volume_id: volume_id,
              capacity_bytes: req.capacity_range.required_bytes,
              volume_context: req.parameters.to_h.merge("size_bytes" => req.capacity_range.required_bytes.to_s),
              accessible_topology: [selected_topology]
            )
          )
        end
        log_with_id(req_id, "create_volume response: #{resp.inspect}")
        resp
      end

      def delete_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "delete_volume request: #{req.inspect}")
        raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.nil?
        raise GRPC::InvalidArgument.new("Volume ID is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_id.nil? || req.volume_id.empty?

        client = KubernetesClient.new(req_id:)
        pv_name = @mutex.synchronize { @volume_store.find { |_, d| d[:volume_id] == req.volume_id }&.first }
        pv = pv_name.nil? ? client.find_pv_by_volume_id(req.volume_id) : client.get_pv(pv_name)
        pv_node = client.extract_node_from_pv(pv)
        pv_node_ip = client.get_node_ip(pv_node)
        file_path = NodeService.backing_file_path(req.volume_id)
        delete_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-i", "/ssh/id_ed25519", "ubi@#{pv_node_ip}",
          "sudo", "rm", "-f", file_path]
        output, status = run_cmd(*delete_cmd, req_id:)
        if !status.success?
          log_with_id(req_id, "Could not delete the PV's backing file: #{output}")
          raise GRPC::Internal, "Could not delete the PV's backing file"
        end
        @mutex.synchronize { @volume_store.delete(pv_name) }

        resp = DeleteVolumeResponse.new
        log_with_id(req_id, "delete_volume response: #{resp.inspect}")
        resp
      rescue GRPC::InvalidArgument => e
        log_with_id(req_id, "Handled gRPC validation error in delete_volume: #{e.class} - #{e.message}}")
        raise e
      rescue => e
        log_with_id(req_id, "Internal error in delete_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
        raise GRPC::Internal, "DeleteVolume error: #{e.message}"
      end
    end
  end
end
