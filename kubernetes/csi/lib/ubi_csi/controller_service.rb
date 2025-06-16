# frozen_string_literal: true

require "grpc"
require "securerandom"
require_relative "../csi_services_pb"

module Csi
  module V1
    class ControllerService < Controller::Service
      MAX_VOLUME_SIZE = 2 * 1024 * 1024 * 1024 # 2GB in bytes

      def initialize
        @volume_store = {} # Maps volume name to volume details
        @mutex = Mutex.new
      end

      def controller_get_capabilities(req, _call)
        if req.nil?
          raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT)
        end

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

      def create_volume(req, _call)
        raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.nil?
        raise GRPC::InvalidArgument.new("Volume name is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.name.nil? || req.name.empty?
        raise GRPC::InvalidArgument.new("Capacity range is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.nil?
        raise GRPC::InvalidArgument.new("Required bytes must be specified", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.required_bytes.nil?
        raise GRPC::InvalidArgument.new("Required bytes must be positive", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.capacity_range.required_bytes <= 0
        raise GRPC::InvalidArgument.new("Volume size exceeds maximum allowed size of 2GB", GRPC::Core::StatusCodes::OUT_OF_RANGE) if req.capacity_range.required_bytes > MAX_VOLUME_SIZE
        raise GRPC::InvalidArgument.new("Volume capabilities are required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_capabilities.nil? || req.volume_capabilities.empty?

        @mutex.synchronize do
          if @volume_store[req.name]
            existing = @volume_store[req.name]

            if existing[:key][:capacity_bytes] != req.capacity_range.required_bytes
              raise GRPC::FailedPrecondition.new("Volume with same name but different size exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            if existing[:key][:parameters] != req.parameters.to_h
              raise GRPC::FailedPrecondition.new("Volume with same name but different parameters exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            existing_capabilities = existing[:key][:capabilities].sort_by { |cap| cap.to_json }
            new_capabilities = req.volume_capabilities.map(&:to_h).sort_by { |cap| cap.to_json }

            if existing_capabilities != new_capabilities
              raise GRPC::FailedPrecondition.new("Volume with same name but different capabilities exists", GRPC::Core::StatusCodes::FAILED_PRECONDITION)
            end

            return CreateVolumeResponse.new(
              volume: Volume.new(
                volume_id: existing[:volume_id],
                capacity_bytes: req.capacity_range.required_bytes,
                volume_context: req.parameters.to_h
              )
            )
          end

          volume_id = "vol-#{SecureRandom.uuid}"
          @volume_store[req.name] = {
            volume_id: volume_id,
            key: {
              name: req.name,
              capacity_bytes: req.capacity_range.required_bytes,
              parameters: req.parameters.to_h,
              capabilities: req.volume_capabilities.map(&:to_h)
            }
          }

          CreateVolumeResponse.new(
            volume: Volume.new(
              volume_id: volume_id,
              capacity_bytes: req.capacity_range.required_bytes,
              volume_context: req.parameters.to_h
            )
          )
        end
      end

      def delete_volume(req, _call)
        raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.nil?
        raise GRPC::InvalidArgument.new("Volume ID is required", GRPC::Core::StatusCodes::INVALID_ARGUMENT) if req.volume_id.nil? || req.volume_id.empty?

        @mutex.synchronize do
          @volume_store.delete_if { |_, details| details[:volume_id] == req.volume_id }
        end

        DeleteVolumeResponse.new
      end
    end
  end
end
