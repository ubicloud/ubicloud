# frozen_string_literal: true

require "grpc"
require "fileutils"
require "socket"
require "yaml"
require "shellwords"
require "base64"
require_relative "errors"
require_relative "kubernetes_client"
require_relative "../csi_services_pb"

module Csi
  module V1
    class NodeService < Node::Service
      include Csi::ServiceHelper

      MAX_VOLUMES_PER_NODE = 8
      VOLUME_BASE_PATH = "/var/lib/ubicsi"
      OLD_PV_NAME_ANNOTATION_KEY = "csi.ubicloud.com/old-pv-name"
      OLD_PVC_OBJECT_ANNOTATION_KEY = "csi.ubicloud.com/old-pvc-object"

      def self.mkdir_p
        FileUtils.mkdir_p(VOLUME_BASE_PATH)
      end

      def initialize(logger:, node_id:)
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

      def run_cmd_output(*cmd, req_id:)
        output, _ = run_cmd(*cmd, req_id:)
        output
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

      def pvc_needs_migration?(pvc)
        old_pv_name = pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY)
        !old_pv_name.nil?
      end
      alias_method :is_copied_pvc?, :pvc_needs_migration?

      def node_stage_volume(req, _call)
        log_request_response(req, "node_stage_volume") do |req_id|
          client = KubernetesClient.new(req_id:, logger: @logger)
          pvc = fetch_and_migrate_pvc(req_id, client, req)
          perform_node_stage_volume(req_id, pvc, req, _call)
          roll_back_reclaim_policy(req_id, client, req, pvc)
          remove_old_pv_annotation(client, pvc)
          NodeStageVolumeResponse.new
        end
      end

      def fetch_and_migrate_pvc(req_id, client, req)
        pvc = client.get_pvc(req.volume_context["csi.storage.k8s.io/pvc/namespace"],
          req.volume_context["csi.storage.k8s.io/pvc/name"])
        if pvc_needs_migration?(pvc)
          migrate_pvc_data(req_id, client, pvc, req)
        end

        pvc
      rescue CopyNotFinishedError => e
        log_with_id(req_id, "Waiting for data copy to finish in node_stage_volume: #{e.message}")
        raise GRPC::Internal, e.message
      rescue => e
        log_with_id(req_id, "Internal error in node_stage_volume: #{e.class} - #{e.message} - #{e.backtrace}")
        raise GRPC::Internal, "Unexpected error: #{e.class} - #{e.message}"
      end

      def perform_node_stage_volume(req_id, pvc, req, _call)
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

          should_mkfs = is_new_loop_device
          # in the case of copied PVCs, the previous has run the mkfs and by doing it again,
          # we would wipe data so we avoid it here
          if is_copied_pvc?(pvc)
            should_mkfs = false
          end
          if !req.volume_capability.mount.nil? && should_mkfs
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
      end

      def remove_old_pv_annotation(client, pvc)
        if !pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY).nil?
          pvc["metadata"]["annotations"].delete(OLD_PV_NAME_ANNOTATION_KEY)
          client.update_pvc(pvc)
        end
      end

      def roll_back_reclaim_policy(req_id, client, req, pvc)
        old_pv_name = pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY)
        if old_pv_name.nil?
          return
        end
        pv = client.get_pv(old_pv_name)
        if pv.dig("spec", "persistentVolumeReclaimPolicy") == "Retain"
          pv["spec"]["persistentVolumeReclaimPolicy"] = "Delete"
          client.update_pv(pv)
        end
      rescue => e
        log_with_id(req_id, "Internal error in node_stage_volume: #{e.class} - #{e.message} - #{e.backtrace}")
        raise GRPC::Internal, "Unexpected error: #{e.class} - #{e.message}"
      end

      def migrate_pvc_data(req_id, client, pvc, req)
        old_pv_name = pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY)
        pv = client.get_pv(old_pv_name)
        pv_node = client.extract_node_from_pv(pv)
        old_node_ip = client.get_node_ip(pv_node)
        old_data_path = NodeService.backing_file_path(pv["spec"]["csi"]["volumeHandle"])
        current_data_path = NodeService.backing_file_path(req.volume_id)

        daemonizer_unit_name = Shellwords.shellescape("copy_#{old_pv_name}")
        case run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "check", daemonizer_unit_name, req_id:)
        when "Succeeded"
          run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "clean", daemonizer_unit_name, req_id:)
        when "NotStarted"
          copy_command = ["rsync", "-az", "--inplace", "--compress-level=9", "--partial", "--whole-file", "-e", "ssh -T -c aes128-gcm@openssh.com -o Compression=no -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /home/ubi/.ssh/id_ed25519", "ubi@#{old_node_ip}:#{old_data_path}", current_data_path]
          run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "run", daemonizer_unit_name, *copy_command, req_id:)
          raise CopyNotFinishedError, "Old PV data is not copied yet"
        when "InProgress"
          raise CopyNotFinishedError, "Old PV data is not copied yet"
        when "Failed"
          raise "Copy old PV data failed"
        else
          raise "Daemonizer2 returned unknown status"
        end
      end

      def node_unstage_volume(req, _call)
        log_request_response(req, "node_unstage_volume") do |req_id|
          begin
            client = KubernetesClient.new(req_id:, logger: @logger)
            if !client.node_schedulable?(@node_id)
              prepare_data_migration(client, req_id, req.volume_id)
            end
            staging_path = req.staging_target_path
            if is_mounted?(staging_path, req_id:)
              output, ok = run_cmd("umount", "-q", staging_path, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_unstage_volume: failed to umount device: #{output}")
                raise GRPC::Internal, "Failed to unmount #{staging_path}: #{output}"
              end
            end
          rescue GRPC::BadStatus => e
            log_with_id(req_id, "gRPC error in node_unstage_volume: #{e.class} - #{e.message}")
            raise e
          rescue => e
            log_with_id(req_id, "Internal error in node_unstage_volume: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise GRPC::Internal, "NodeUnstageVolume error: #{e.class} - #{e.message}"
          end
          NodeUnstageVolumeResponse.new
        end
      end

      def prepare_data_migration(client, req_id, volume_id)
        log_with_id(req_id, "Retaining pv with volume_id #{volume_id}")
        pv = retain_pv(req_id, client, volume_id)
        log_with_id(req_id, "Recreating pvc with volume_id #{volume_id}")
        recreate_pvc(req_id, client, pv)
      end

      def retain_pv(req_id, client, volume_id)
        pv = client.find_pv_by_volume_id(volume_id)
        log_with_id(req_id, "Found PV with volume_id #{volume_id}: #{pv}")
        if pv.dig("spec", "persistentVolumeReclaimPolicy") != "Retain"
          pv["spec"]["persistentVolumeReclaimPolicy"] = "Retain"
          client.update_pv(pv)
          log_with_id(req_id, "Updated PV to retain")
        end
        pv
      end

      def recreate_pvc(req_id, client, pv)
        pvc_namespace, pvc_name = pv["spec"]["claimRef"].values_at("namespace", "name")

        begin
          pvc = client.get_pvc(pvc_namespace, pvc_name)
        rescue ObjectNotFoundError => e
          old_pvc_object = pv.dig("metadata", "annotations", OLD_PVC_OBJECT_ANNOTATION_KEY)
          if old_pvc_object.empty?
            raise e
          end
          pvc = YAML.load(Base64.decode64(old_pvc_object))
        end
        log_with_id(req_id, "Found matching PVC for PV #{pv["metadata"]["name"]}: #{pvc}")

        pvc = trim_pvc(pvc, pv["metadata"]["name"])
        log_with_id(req_id, "Trimmed PVC for recreation: #{pvc}")

        base64_encoded_pvc = Base64.strict_encode64(YAML.dump(pvc))
        if pv.dig("metadata", "annotations", OLD_PVC_OBJECT_ANNOTATION_KEY) != base64_encoded_pvc
          pv["metadata"]["annotations"][OLD_PVC_OBJECT_ANNOTATION_KEY] = base64_encoded_pvc
          pv["metadata"].delete("resourceVersion")
          client.update_pv(pv)
        end

        client.delete_pvc(pvc_namespace, pvc_name)
        log_with_id(req_id, "Deleted PVC #{pvc_namespace}/#{pvc_name}")
        client.create_pvc(pvc)
        log_with_id(req_id, "Recreated PVC with the new spec")
      end

      def trim_pvc(pvc, pv_name)
        pvc["metadata"]["annotations"] = {OLD_PV_NAME_ANNOTATION_KEY => pv_name}
        %w[resourceVersion uid creationTimestamp].each do |key|
          pvc["metadata"].delete(key)
        end
        pvc["spec"].delete("volumeName")
        pvc.delete("status")
        pvc
      end

      def node_publish_volume(req, _call)
        log_request_response(req, "node_publish_volume") do |req_id|
          staging_path = req.staging_target_path
          target_path = req.target_path
          begin
            unless is_mounted?(target_path, req_id:)
              FileUtils.mkdir_p(target_path)
              output, ok = run_cmd("mount", "--bind", staging_path, target_path, req_id:)
              unless ok
                log_with_id(req_id, "gRPC error in node_publish_volume: failed to bind mount device: #{output}")
                raise GRPC::Internal, "Failed to bind mount #{staging_path} to #{target_path}: #{output}"
              end
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
            if is_mounted?(target_path, req_id:)
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
