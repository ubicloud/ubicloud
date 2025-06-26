# frozen_string_literal: true

require "grpc"
require "fileutils"
require "open3"
require "socket"
require_relative "../csi_services_pb"

module Csi
  module V1
    class NodeService < Node::Service
      MAX_VOLUMES_PER_NODE = 8
      VOLUME_BASE_PATH = "/var/lib/ubi-csi"

      def node_get_capabilities(req, _call)
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

      def node_get_info(req, _call)
        NodeGetInfoResponse.new(
          node_id: Socket.gethostname,
          max_volumes_per_node: MAX_VOLUMES_PER_NODE
        )
      end

      def run_cmd(*cmd)
        output, status = Open3.capture2e(*cmd)
        unless status.success?
          warn "[CSI NodeService] Command failed: #{cmd.join(" ")}\nOutput: #{output}"
        end
        [output, status.success?]
      end

      def node_stage_volume(req, _call)
        volume_id = req.volume_id
        staging_path = req.staging_target_path
        size_bytes = req.volume_context["size_bytes"].to_i
        backing_file = File.join(VOLUME_BASE_PATH, "#{volume_id}.img")
        FileUtils.mkdir_p(File.dirname(backing_file))

        begin
          unless File.exist?(backing_file)
            output, ok = run_cmd("fallocate", "-l", size_bytes.to_s, backing_file)
            unless ok
              raise GRPC::ResourceExhausted, "Failed to allocate backing file: #{output}"
            end
            output, ok = run_cmd("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file)
            unless ok
              raise GRPC::ResourceExhausted, "Failed to punch hole in backing file: #{output}"
            end
          end

          loop_device, ok = run_cmd("sudo", "losetup", "--find", "--show", backing_file)
          loop_device = loop_device.strip
          unless ok && !loop_device.empty?
            raise GRPC::Internal, "Failed to setup loop device: #{loop_device}"
          end

          if req.volume_capability&.mount
            fs_type = req.volume_capability.mount.fs_type.presence || "ext4"
            output, ok = run_cmd("sudo", "mkfs.#{fs_type}", loop_device)
            unless ok
              raise GRPC::Internal, "Failed to format device #{loop_device} with #{fs_type}: #{output}"
            end
            FileUtils.mkdir_p(staging_path)
            output, ok = run_cmd("sudo", "mount", loop_device, staging_path)
            unless ok
              raise GRPC::Internal, "Failed to mount #{loop_device} to #{staging_path}: #{output}"
            end
          end
          # If block, do nothing else (no format, no mount)
        rescue GRPC::BadStatus => e
          warn "[CSI NodeService] gRPC error in node_stage_volume: #{e.class} - #{e.message}"
          raise e
        rescue => e
          warn "[CSI NodeService] Internal error in node_stage_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
          raise GRPC::Internal, "NodeStageVolume error: #{e.message}"
        end
        NodeStageVolumeResponse.new
      end

      def node_unstage_volume(req, _call)
        staging_path = req.staging_target_path
        begin
          output, ok = run_cmd("sudo", "umount", staging_path)
          unless ok
            raise GRPC::Internal, "Failed to unmount #{staging_path}: #{output}"
          end
        rescue GRPC::BadStatus => e
          warn "[CSI NodeService] gRPC error in node_unstage_volume: #{e.class} - #{e.message}"
          raise e
        rescue => e
          warn "[CSI NodeService] Internal error in node_unstage_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
          raise GRPC::Internal, "NodeUnstageVolume error: #{e.message}"
        end
        NodeUnstageVolumeResponse.new
      end

      def node_publish_volume(req, _call)
        staging_path = req.staging_target_path
        target_path = req.target_path
        begin
          FileUtils.mkdir_p(target_path)
          output, ok = run_cmd("sudo", "mount", "--bind", staging_path, target_path)
          unless ok
            raise GRPC::Internal, "Failed to bind mount #{staging_path} to #{target_path}: #{output}"
          end
        rescue GRPC::BadStatus => e
          warn "[CSI NodeService] gRPC error in node_publish_volume: #{e.class} - #{e.message}"
          raise e
        rescue => e
          warn "[CSI NodeService] Internal error in node_publish_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
          raise GRPC::Internal, "NodePublishVolume error: #{e.message}"
        end
        NodePublishVolumeResponse.new
      end

      def node_unpublish_volume(req, _call)
        target_path = req.target_path
        begin
          output, ok = run_cmd("sudo", "umount", target_path)
          unless ok
            raise GRPC::Internal, "Failed to unmount #{target_path}: #{output}"
          end
        rescue GRPC::BadStatus => e
          warn "[CSI NodeService] gRPC error in node_unpublish_volume: #{e.class} - #{e.message}"
          raise e
        rescue => e
          warn "[CSI NodeService] Internal error in node_unpublish_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
          raise GRPC::Internal, "NodeUnpublishVolume error: #{e.message}"
        end
        NodeUnpublishVolumeResponse.new
      end
    end
  end
end
