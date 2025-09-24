# frozen_string_literal: true

require "grpc"
require "json"
require "securerandom"
require_relative "../csi_services_pb"

module Csi
  module V1
    class ControllerService < Controller::Service
      include Csi::ServiceHelper

      OneGB = 1024 * 1024 * 1024

      def max_volume_size
        @max_volume_size ||= begin
          limit_gb_str = ENV.fetch("DISK_LIMIT_GB", "10")
          limit_gb = limit_gb_str.to_i
          limit_gb * OneGB
        end
      end

      def initialize(logger:)
        @logger = logger
        @volume_store = {} # Maps volume name to volume details
        @mutex = Mutex.new
      end

      def controller_get_capabilities(req, _call)
        log_request_response(req, "controller_get_capabilities") do |req_id|
          ControllerGetCapabilitiesResponse.new(
            capabilities: [
              ControllerServiceCapability.new(
                rpc: ControllerServiceCapability::RPC.new(
                  type: ControllerServiceCapability::RPC::Type::CREATE_DELETE_VOLUME
                )
              )
            ]
          )
        end
      end

      # We advertise PluginCapability::Service::Type::VOLUME_ACCESSIBILITY_CONSTRAINTS
      # as one of the plugin capabilities in IdentityPlugin. This plugin allows us
      # to stick the PVs to the node they are scheduled on so they won't jump around
      # during regular pod deletes.
      #
      # This function will be used in CreateVolume method,
      # Telling the kubernetes cluster first to not select control-plane nodes,
      # then selecting any of the nodes which might can host the PV.
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
        log_request_response(req, "create_volume") do |req_id|
          raise GRPC::InvalidArgument.new("Volume name is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.name.nil? || req.name.empty?
          raise GRPC::InvalidArgument.new("Capacity range is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.nil?
          raise GRPC::InvalidArgument.new("Required bytes must be positive", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.required_bytes <= 0
          raise GRPC::InvalidArgument.new("Volume size exceeds maximum allowed size of #{max_volume_size / OneGB}GB", GRPC::Core::StatusCodes::OUT_OF_RANGE) if req.capacity_range.required_bytes > max_volume_size
          raise GRPC::InvalidArgument.new("Volume capabilities are required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_capabilities.nil? || req.volume_capabilities.empty?
          raise GRPC::InvalidArgument.new("Topology requirement is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.accessibility_requirements.nil? || req.accessibility_requirements.requisite.empty?

          existing = nil
          new_volume_id = nil
          selected_topology = nil

          @mutex.synchronize do
            unless (existing = @volume_store[req.name])
              selected_topology = select_worker_topology(req)
              new_volume_id = "vol-#{SecureRandom.uuid}"
              @volume_store[req.name] = {
                volume_id: new_volume_id,
                name: req.name.freeze,
                accessible_topology: selected_topology.freeze,
                capacity_bytes: req.capacity_range.required_bytes,
                parameters: req.parameters.to_h.transform_values(&:freeze).freeze,
                capabilities: req.volume_capabilities.map(&:to_h).freeze
              }.freeze
            end
          end

          if existing
            if req.accessibility_requirements.requisite.first != existing[:accessible_topology]
              raise GRPC::FailedPrecondition.new("Existing volume has incompatible topology", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end
            if existing[:capacity_bytes] != req.capacity_range.required_bytes
              raise GRPC::FailedPrecondition.new("Volume with same name but different size exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end
            if existing[:parameters] != req.parameters.to_h
              raise GRPC::FailedPrecondition.new("Volume with same name but different parameters exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end
            existing_capabilities = existing[:capabilities].sort_by(&:to_json)
            new_capabilities = req.volume_capabilities.map(&:to_h).sort_by(&:to_json)
            if existing_capabilities != new_capabilities
              raise GRPC::FailedPrecondition.new("Volume with same name but different capabilities exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end
          end

          volume_id = existing ? existing[:volume_id] : new_volume_id
          topology = existing ? existing[:accessible_topology] : selected_topology
          CreateVolumeResponse.new(
            volume: Volume.new(
              volume_id: volume_id,
              capacity_bytes: req.capacity_range.required_bytes,
              volume_context: req.parameters.to_h.merge("size_bytes" => req.capacity_range.required_bytes.to_s),
              accessible_topology: [topology]
            )
          )
        end
      end

      def delete_volume(req, _call)
        log_request_response(req, "delete_volume") do |req_id|
          raise GRPC::InvalidArgument.new("Volume ID is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_id.nil? || req.volume_id.empty?

          client = KubernetesClient.new(req_id:, logger: @logger)
          # Since we would have at most 8 PVCs per node, searching by value will not cause overhead
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

          DeleteVolumeResponse.new
        rescue GRPC::InvalidArgument => e
          log_with_id(req_id, "Handled gRPC validation error in delete_volume: #{e.class} - #{e.message}")
          raise
        rescue => e
          log_with_id(req_id, "Internal error in delete_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
          raise GRPC::Internal, "DeleteVolume error: #{e.message}"
        end
      end
    end
  end
end
