# frozen_string_literal: true

require "grpc"
require "fileutils"
require "open3"
require "socket"
require "logger"
require_relative "../csi_services_pb"

module Csi
  module V1
    class NodeService < Node::Service
      MAX_VOLUMES_PER_NODE = 8
      VOLUME_BASE_PATH = "/var/lib/ubicsi"
      LOGGER = Logger.new($stdout)

      def log_with_id(id, message)
        LOGGER.info("[req_id=#{id}] [CSI NodeService] #{message}")
      end

      def node_name
        ENV["NODE_ID"]
      end

      def node_get_capabilities(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_get_capabilities request: #{req.inspect}")
        resp = NodeGetCapabilitiesResponse.new(
          capabilities: [
            NodeServiceCapability.new(
              rpc: NodeServiceCapability::RPC.new(
                type: NodeServiceCapability::RPC::Type::STAGE_UNSTAGE_VOLUME
              )
            )
          ]
        )
        log_with_id(req_id, "node_get_capabilities response: #{resp.inspect}")
        resp
      end

      def node_get_info(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_get_info request: #{req.inspect}")
        topology = Topology.new(
          segments: {
            "kubernetes.io/hostname" => node_name
          }
        )
        resp = NodeGetInfoResponse.new(
          node_id: node_name,
          max_volumes_per_node: MAX_VOLUMES_PER_NODE,
          accessible_topology: topology
        )

        log_with_id(req_id, "node_get_info response: #{resp.inspect}")
        resp
      end

      def run_cmd(*cmd, req_id: nil)
        log_with_id(req_id, "Running command: #{cmd}") unless req_id.nil?
        Open3.capture2e(*cmd)
      end

      def is_mounted?(path, req_id: nil)
        _, status = run_cmd("mountpoint", "-q", path, req_id:)
        status == 0
      end

      def find_loop_device(backing_file)
        output, ok = run_cmd("losetup", "-j", backing_file)
        if ok && !output.empty?
          loop_device = output.split(":")[0].strip
          return loop_device if loop_device.start_with?("/dev/loop")
        end
        nil
      end

      def self.backing_file_path(volume_id)
        File.join(VOLUME_BASE_PATH, "#{volume_id}.img")
      end

      def node_stage_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_stage_volume request: #{req.inspect}")
        volume_id = req.volume_id
        staging_path = req.staging_target_path
        size_bytes = req.volume_context["size_bytes"].to_i
        backing_file = NodeService.backing_file_path(volume_id)
        unless Dir.exist?(VOLUME_BASE_PATH)
          log_with_id(req_id, "Creating backing file's directory #{VOLUME_BASE_PATH}")
          FileUtils.mkdir_p(VOLUME_BASE_PATH)
        end

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

          loop_device = find_loop_device(backing_file)
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
        resp = NodeStageVolumeResponse.new
        log_with_id(req_id, "node_stage_volume response: #{resp.inspect}")
        resp
      end

      def node_unstage_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_unstage_volume request: #{req.inspect}")
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
        resp = NodeUnstageVolumeResponse.new
        log_with_id(req_id, "node_unstage_volume response: #{resp.inspect}")
        resp
      end

      def node_publish_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_publish_volume request: #{req.inspect}")
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
        resp = NodePublishVolumeResponse.new
        log_with_id(req_id, "node_publish_volume response: #{resp.inspect}")
        resp
      end

      def node_unpublish_volume(req, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "node_unpublish_volume request: #{req.inspect}")
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
        resp = NodeUnpublishVolumeResponse.new
        log_with_id(req_id, "node_unpublish_volume response: #{resp.inspect}")
        resp
      end
    end
  end
end
