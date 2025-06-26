# frozen_string_literal: true

require "grpc"
require "fileutils"
require "socket"
require_relative "../csi_services_pb"

module Csi
  module V1
    class NodeService < Node::Service
      include Csi::ServiceHelper

      MAX_VOLUMES_PER_NODE = 8
      VOLUME_BASE_PATH = "/var/lib/ubicsi"

      def initialize(logger:, node_id:)
        FileUtils.mkdir_p(VOLUME_BASE_PATH) unless Dir.exist?(VOLUME_BASE_PATH)
        @logger = logger
        @node_id = node_id
      end

      attr_reader :node_id

      def node_get_capabilities(req, _call)
        log_request_response(req, "node_get_capabilities") do |req_id|
          NodeGetCapabilitiesResponse.new(
            capabilities: [
              NodeServiceCapability.new(
                rpc: NodeServiceCapability::RPC.new(
                  type: NodeServiceCapability::RPC::Type::STAGE_UNSTAGE_VOLUME
                )
              )
            ]
          )
        end
      end

      def node_get_info(req, _call)
        log_request_response(req, "node_get_info") do |req_id|
          topology = Topology.new(
            segments: {
              "kubernetes.io/hostname" => @node_id
            }
          )
          NodeGetInfoResponse.new(
            node_id: @node_id,
            max_volumes_per_node: MAX_VOLUMES_PER_NODE,
            accessible_topology: topology
          )
        end
      end

      def is_mounted?(path, req_id:)
        _, status = run_cmd("mountpoint", "-q", path, req_id:)
        status == 0
      end

      def find_loop_device(backing_file, req_id:)
        output, ok = run_cmd("losetup", "-j", backing_file, req_id:)
        if ok && !output.empty?
          loop_device = output.split(":", 2)[0].strip
          return loop_device if loop_device.start_with?("/dev/loop")
        end
        nil
      end

      def self.backing_file_path(volume_id)
        File.join(VOLUME_BASE_PATH, "#{volume_id}.img")
      end

      def node_stage_volume(req, _call)
        log_request_response(req, "node_stage_volume") do |req_id|
          volume_id = req.volume_id
          staging_path = req.staging_target_path
          size_bytes = Integer(req.volume_context["size_bytes"], 10)
          backing_file = NodeService.backing_file_path(volume_id)

          begin
            unless File.exist?(backing_file)
              output, ok = run_cmd("fallocate", "-l", size_bytes.to_s, backing_file, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_stage_volume: failed to fallocate: #{output}")
                raise GRPC::ResourceExhausted, "Failed to allocate backing file: #{output}"
              end
              output, ok = run_cmd("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_stage_volume: failed to punchhole: #{output}")
                raise GRPC::ResourceExhausted, "Failed to punch hole in backing file: #{output}"
              end
            end

            loop_device = find_loop_device(backing_file, req_id:)
            is_new_loop_device = loop_device.nil?
            if is_new_loop_device
              log_with_id(req_id, "Setting up new loop device for: #{backing_file}")
              output, ok = run_cmd("losetup", "--find", "--show", backing_file, req_id:)
              loop_device = output.strip
              unless ok && !loop_device.empty?
                raise GRPC::Internal, "Failed to setup loop device: #{output}"
              end
            else
              log_with_id(req_id, "Loop device already exists: #{loop_device}")
            end

            if req.volume_capability&.mount && is_new_loop_device
              fs_type = req.volume_capability.mount.fs_type || "ext4"
              output, ok = run_cmd("mkfs.#{fs_type}", loop_device, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_stage_volume: failed to format device: #{output}")
                raise GRPC::Internal, "Failed to format device #{loop_device} with #{fs_type}: #{output}"
              end
            end
            unless is_mounted?(staging_path, req_id:)
              FileUtils.mkdir_p(staging_path)
              output, ok = run_cmd("mount", loop_device, staging_path, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_stage_volume: failed to mount loop device: #{output}")
                raise GRPC::Internal, "Failed to mount #{loop_device} to #{staging_path}: #{output}"
              end
            end
            # If block, do nothing else
          rescue GRPC::BadStatus => e
            log_with_id(req_id, "gRPC error in node_stage_volume: #{e.class} - #{e.message}")
            raise e
          rescue => e
            log_with_id(req_id, "Internal error in node_stage_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise GRPC::Internal, "NodeStageVolume error: #{e.message}"
          end
          NodeStageVolumeResponse.new
        end
      end

      def node_unstage_volume(req, _call)
        log_request_response(req, "node_unstage_volume") do |req_id|
          staging_path = req.staging_target_path
          begin
            if is_mounted?(staging_path)
              output, ok = run_cmd("umount", "-q", staging_path, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_unstage_volume: failed to umount device: #{output}")
                raise GRPC::Internal, "Failed to unmount #{staging_path}: #{output}"
              end
            else
              log_with_id(req_id, "#{staging_path} is not mounted, skipping umount")
            end
          rescue GRPC::BadStatus => e
            log_with_id(req_id, "gRPC error in node_unstage_volume: #{e.class} - #{e.message}")
            raise e
          rescue => e
            log_with_id(req_id, "Internal error in node_unstage_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise GRPC::Internal, "NodeUnstageVolume error: #{e.message}"
          end
          NodeUnstageVolumeResponse.new
        end
      end

      def node_publish_volume(req, _call)
        log_request_response(req, "node_publish_volume") do |req_id|
          staging_path = req.staging_target_path
          target_path = req.target_path
          begin
            FileUtils.mkdir_p(target_path)
            output, ok = run_cmd("mount", "--bind", staging_path, target_path, req_id:)
            unless ok
              log_with_id(req_id, "gRPC error in node_publish_volume: failed to bind mount device: #{output}")
              raise GRPC::Internal, "Failed to bind mount #{staging_path} to #{target_path}: #{output}"
            end
          rescue GRPC::BadStatus => e
            log_with_id(req_id, "gRPC error in node_publish_volume: #{e.class} - #{e.message}")
            raise e
          rescue => e
            log_with_id(req_id, "Internal error in node_publish_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise GRPC::Internal, "NodePublishVolume error: #{e.message}"
          end
          NodePublishVolumeResponse.new
        end
      end

      def node_unpublish_volume(req, _call)
        log_request_response(req, "node_unpublish_volume") do |req_id|
          target_path = req.target_path
          begin
            if is_mounted?(target_path)
              output, ok = run_cmd("umount", "-q", target_path, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_unpublish_volume: failed to umount device: #{output}")
                raise GRPC::Internal, "Failed to unmount #{target_path}: #{output}"
              end
            else
              log_with_id(req_id, "#{target_path} is not mounted, skipping umount")
            end
          rescue GRPC::BadStatus => e
            log_with_id(req_id, "gRPC error in node_unpublish_volume: #{e.class} - #{e.message}")
            raise e
          rescue => e
            log_with_id(req_id, "Internal error in node_unpublish_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise GRPC::Internal, "NodeUnpublishVolume error: #{e.message}"
          end
          NodeUnpublishVolumeResponse.new
        end
      end
    end
  end
end
