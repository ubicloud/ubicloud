# frozen_string_literal: true

require "grpc"
require "fileutils"
require "socket"
require "yaml"
require "shellwords"
require "base64"
require_relative "errors"
require_relative "kubernetes_client"
require_relative "mesh_connectivity_checker"
require_relative "../csi_services_pb"

module Csi
  module V1
    class NodeService < Node::Service
      include Csi::ServiceHelper

      MAX_VOLUMES_PER_NODE = 8
      VOLUME_BASE_PATH = "/var/lib/ubicsi"
      MAX_MIGRATION_RETRIES = 3
      ACCEPTABLE_FS = ["ext4", "xfs"].freeze

      def self.mkdir_p
        FileUtils.mkdir_p(VOLUME_BASE_PATH)
      end

      def initialize(logger:, node_id:)
        @logger = logger
        @node_id = node_id
        start_mesh_connectivity_checker
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

      def remove_loop_device(backing_file, req_id:)
        loop_device = find_loop_device(backing_file, req_id:)
        return unless loop_device

        output, ok = run_cmd("losetup", "-d", loop_device, req_id:)
        unless ok
          raise "Could not remove loop device: #{output}"
        end
      end

      def self.backing_file_path(volume_id)
        File.join(VOLUME_BASE_PATH, "#{volume_id}.img")
      end

      def pvc_needs_migration?(pvc)
        old_pv_name = pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY)
        !old_pv_name.nil?
      end

      def find_file_system(loop_device, req_id:)
        output, ok = run_cmd("blkid", "-o", "value", "-s", "TYPE", loop_device, req_id:)
        unless ok
          raise "Failed to get the loop device filesystem status: #{output}"
        end

        output.strip
      end

      # TLA \* Models NodeService#node_stage_volume with migration path:
      # TLA \* fetch_and_migrate_pvc -> migrate_pvc_data returns "Succeeded".
      # TLA \* The rsync source is migSource (original data node, preserved by ||=).
      # TLA \* After staging, roll_back_reclaim_policy reverts old PV to Delete,
      # TLA \* and remove_old_pv_annotation_from_pvc clears the annotation.
      # TLA \* Only on nodes where kubelet is running (Active or Draining).
      # TLA NodeStageVolumeWithMigration(v) ==
      # TLA     ∧ phase[v] = Created
      # TLA     ∧ migState[v] = MigDone
      # TLA     ∧ migTarget[v] ∈ Nodes
      # TLA     ∧ LET newNode == migTarget[v] IN
      # TLA        ∧ nodeState[newNode] ∈ {NodeActive, NodeDraining}
      # TLA        ∧ ⟨v, newNode⟩ ∈ backingFiles
      # TLA        ∧ phase'         = [phase EXCEPT ![v] = Staged]
      # TLA        ∧ owner'         = [owner EXCEPT ![v] = newNode]
      # TLA        ∧ loopDevices'   = loopDevices   ∪ {⟨v, newNode⟩}
      # TLA        ∧ stagingMounts' = stagingMounts ∪ {⟨v, newNode⟩}
      # TLA        ∧ migState'      = [migState  EXCEPT ![v] = MigNone]
      # TLA        ∧ migTarget'     = [migTarget EXCEPT ![v] = NoNode]
      # TLA        ∧ migSource'     = [migSource EXCEPT ![v] = NoNode]
      # TLA        ∧ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = FALSE]
      # TLA        ∧ UNCHANGED ⟨backingFiles, targetMounts, nodeSchedulable, nodeState, scenarioPhase⟩
      def node_stage_volume(req, _call)
        log_request_response(req, "node_stage_volume") do |req_id|
          client = KubernetesClient.new(req_id:, logger: @logger)
          pvc = fetch_and_migrate_pvc(req_id, client, req)
          perform_node_stage_volume(req_id, pvc, req, _call)
          # migState' = MigNone ∧ migReclaimRetain' = FALSE  \* roll_back + remove annotation
          roll_back_reclaim_policy(req_id, client, req, pvc)
          remove_old_pv_annotation_from_pvc(req_id, client, pvc)
          NodeStageVolumeResponse.new
        rescue => e
          log_and_raise(req_id, e)
        end
      end

      def fetch_and_migrate_pvc(req_id, client, req)
        pvc_namespace = req.volume_context["csi.storage.k8s.io/pvc/namespace"]
        pvc_name = req.volume_context["csi.storage.k8s.io/pvc/name"]
        pvc = client.get_pvc(pvc_namespace, pvc_name)
        if pvc_needs_migration?(pvc)
          migrate_pvc_data(req_id, client, pvc, req)

        # Fallback: during node drain, recreate_pvc may race with the StatefulSet controller,
        # which can recreate the PVC without the migration annotation. The old PV's
        # old-pvc-object annotation is set before any PVC deletion, so check it as a safety net.
        elsif (old_pv = client.find_retained_pv_for_pvc(pvc_namespace, pvc_name))
          old_pv_name = old_pv.dig("metadata", "name")
          log_with_id(req_id, "PVC missing migration annotation, found retained PV: #{old_pv_name}")
          pvc["metadata"]["annotations"] ||= {}
          pvc["metadata"]["annotations"][OLD_PV_NAME_ANNOTATION_KEY] = old_pv_name
          client.patch_resource("pvc", pvc_name, OLD_PV_NAME_ANNOTATION_KEY, old_pv_name, namespace: pvc_namespace)
          migrate_pvc_data(req_id, client, pvc, req)
        end
        pvc
      end

      # TLA \* Models NodeService#node_stage_volume (no migration path):
      # TLA \* Creates backing file, sets up loop device, formats filesystem, mounts.
      # TLA \* Only on nodes where kubelet is running (Active or Draining).
      # TLA NodeStageVolume(v) ==
      # TLA     ∧ phase[v] = Created
      # TLA     ∧ owner[v] ∈ Nodes
      # TLA     ∧ migState[v] = MigNone
      # TLA     ∧ LET n == owner[v] IN
      # TLA        ∧ nodeState[n] ∈ {NodeActive, NodeDraining}
      # TLA        ∧ phase'         = [phase EXCEPT ![v] = Staged]
      # TLA        ∧ backingFiles'  = backingFiles  ∪ {⟨v, n⟩}
      # TLA        ∧ loopDevices'   = loopDevices   ∪ {⟨v, n⟩}
      # TLA        ∧ stagingMounts' = stagingMounts ∪ {⟨v, n⟩}
      # TLA        ∧ UNCHANGED ⟨owner, targetMounts, nodeSchedulable, nodeState,
      # TLA                       migState, migTarget, migSource,
      # TLA                       migReclaimRetain, scenarioPhase⟩
      def perform_node_stage_volume(req_id, pvc, req, _call)
        volume_id = req.volume_id
        staging_path = req.staging_target_path
        size_bytes = Integer(req.volume_context["size_bytes"], 10)
        backing_file = NodeService.backing_file_path(volume_id)

        # backingFiles' ∪= {⟨v, n⟩}   \* fallocate backing file
        unless File.exist?(backing_file)
          output, ok = run_cmd("fallocate", "-l", size_bytes.to_s, backing_file, req_id:)
          unless ok
            raise GRPC::ResourceExhausted.new("Failed to allocate backing file: #{output}")
          end

          output, ok = run_cmd("fallocate", "--punch-hole", "--keep-size", "-o", "0", "-l", size_bytes.to_s, backing_file, req_id:)
          unless ok
            raise GRPC::ResourceExhausted.new("Failed to punch hole in backing file: #{output}")
          end
        end

        # loopDevices' ∪= {⟨v, n⟩}    \* losetup --find --show
        loop_device = find_loop_device(backing_file, req_id:)
        is_new_loop_device = loop_device.nil?
        if is_new_loop_device
          log_with_id(req_id, "Setting up new loop device for: #{backing_file}")
          output, ok = run_cmd("losetup", "--find", "--show", backing_file, req_id:)
          loop_device = output.strip
          unless ok && !loop_device.empty?
            raise "Failed to setup loop device: #{output}"
          end
        else
          log_with_id(req_id, "Loop device already exists: #{loop_device}")
        end

        if req.volume_capability.mount
          current_fs_type = find_file_system(loop_device, req_id:)
          if !current_fs_type.empty? && !ACCEPTABLE_FS.include?(current_fs_type)
            raise "Unacceptable file system type for #{loop_device}: #{current_fs_type}"
          end

          desired_fs_type = req.volume_capability.mount.fs_type || "ext4"
          if current_fs_type != "" && current_fs_type != desired_fs_type
            raise "Unexpected filesystem on volume. desired: #{desired_fs_type}, current: #{current_fs_type}"
          elsif current_fs_type == ""
            output, ok = run_cmd("mkfs.#{desired_fs_type}", loop_device, req_id:)
            unless ok
              raise "Failed to format device #{loop_device} with #{desired_fs_type}: #{output}"
            end
          end
        end
        # stagingMounts' ∪= {⟨v, n⟩}  \* mount loop_device staging_path
        unless is_mounted?(staging_path, req_id:)
          FileUtils.mkdir_p(staging_path)
          output, ok = run_cmd("mount", loop_device, staging_path, req_id:)
          unless ok
            raise "Failed to mount #{loop_device} to #{staging_path}: #{output}"
          end
        end
        # If block, do nothing else
      end

      def remove_old_pv_annotation_from_pvc(req_id, client, pvc)
        namespace, name = pvc["metadata"].values_at("namespace", "name")
        log_with_id(req_id, "Removing old pv annotation #{OLD_PV_NAME_ANNOTATION_KEY}")
        client.remove_pvc_annotation(namespace, name, OLD_PV_NAME_ANNOTATION_KEY)
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
        # TLA \* CompleteMigrationCopy: daemonizer2 "Succeeded" → backingFiles' ∪= {⟨v, newNode⟩}
        when "Succeeded"
          # TLA CompleteMigrationCopy(v) ==
          # TLA     ∧ migState[v] = MigCopying
          # TLA     ∧ migTarget[v] ∈ Nodes
          # TLA     ∧ migSource[v] ∈ Nodes
          # TLA     ∧ ⟨v, migSource[v]⟩ ∈ backingFiles
          # TLA     ∧ LET newNode == migTarget[v] IN
          # TLA        ∧ backingFiles' = backingFiles ∪ {⟨v, newNode⟩}
          # TLA        ∧ migState'     = [migState EXCEPT ![v] = MigDone]
          # TLA        ∧ UNCHANGED ⟨phase, owner, loopDevices, stagingMounts, targetMounts,
          # TLA                       nodeSchedulable, nodeState, migTarget, migSource,
          # TLA                       migReclaimRetain, scenarioPhase⟩
          run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "clean", daemonizer_unit_name, req_id:)
          if pv.dig("metadata", "annotations", MIGRATION_RETRY_COUNT_ANNOTATION_KEY)
            client.patch_resource("pv", old_pv_name, MIGRATION_RETRY_COUNT_ANNOTATION_KEY, nil)
          end
        # TLA \* StartMigrationCopy: daemonizer2 "NotStarted" → run rsync
        when "NotStarted"
          # TLA StartMigrationCopy(v) ==
          # TLA     ∧ migState[v] = MigPrepared
          # TLA     ∧ migTarget[v] ∈ Nodes
          # TLA     ∧ migSource[v] ∈ Nodes
          # TLA     ∧ ⟨v, migSource[v]⟩ ∈ backingFiles    \* source data must exist
          # TLA     ∧ migState' = [migState EXCEPT ![v] = MigCopying]
          # TLA     ∧ UNCHANGED ⟨phase, owner, backingFiles, loopDevices, stagingMounts,
          # TLA                    targetMounts, nodeSchedulable, nodeState, migTarget,
          # TLA                    migSource, migReclaimRetain, scenarioPhase⟩
          copy_command = ["rsync", "-az", "--inplace", "--compress-level=9", "--partial", "--whole-file", "-e", "ssh -T -c aes128-gcm@openssh.com -o Compression=no -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /home/ubi/.ssh/id_ed25519", "ubi@#{old_node_ip}:#{old_data_path}", current_data_path]
          run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "run", daemonizer_unit_name, *copy_command, req_id:)
          raise CopyNotFinishedError, "Old PV data is not copied yet"
        when "InProgress"
          raise CopyNotFinishedError, "Old PV data is not copied yet"
        when "Failed"
          retry_count = Integer(pv.dig("metadata", "annotations", MIGRATION_RETRY_COUNT_ANNOTATION_KEY) || "0", 10)
          # NOTE: ExhaustMigrationRetries and retry counting are intentionally
          # omitted from the TLA+ proof (see proof/csi/header.tla for rationale).
          # The proof assumes rsync is eventually reliable; the retry budget is a
          # defense-in-depth mechanism for permanent failures.
          if retry_count >= MAX_MIGRATION_RETRIES
            raise "Migration copy failed after #{MAX_MIGRATION_RETRIES} attempts, please contact support"
          end
          # TLA \* FailMigrationCopy: daemonizer2 "Failed" → MigFailed + CopyNotFinishedError
          # TLA FailMigrationCopy(v) ==
          # TLA     ∧ migState[v] = MigCopying
          # TLA     ∧ migTarget[v] ∈ Nodes
          # TLA     ∧ migState' = [migState EXCEPT ![v] = MigFailed]
          # TLA     ∧ UNCHANGED ⟨phase, owner, backingFiles, loopDevices, stagingMounts,
          # TLA                    targetMounts, nodeSchedulable, nodeState, migTarget,
          # TLA                    migSource, migReclaimRetain, scenarioPhase⟩
          retry_count += 1
          client.patch_resource("pv", old_pv_name, MIGRATION_RETRY_COUNT_ANNOTATION_KEY, retry_count.to_s)
          run_cmd_output("nsenter", "-t", "1", "-a", "/home/ubi/common/bin/daemonizer2", "clean", daemonizer_unit_name, req_id:)
          log_with_id(req_id, "Migration copy failed, retrying (attempt #{retry_count})")
          raise CopyNotFinishedError, "Old PV data copy failed, retrying (attempt #{retry_count})"
        else
          raise "Daemonizer2 returned unknown status"
        end
      end

      # TLA \* Models NodeService#node_unstage_volume when node IS schedulable:
      # TLA \* Tears down loop device and unmounts staging path.
      # TLA NodeUnstageVolumeNormal(v) ==
      # TLA     ∧ phase[v] = Staged
      # TLA     ∧ owner[v] ∈ Nodes
      # TLA     ∧ LET n == owner[v] IN
      # TLA        ∧ ⟨v, n⟩ ∉ targetMounts
      # TLA        ∧ nodeSchedulable[n] = TRUE
      # TLA        ∧ phase'         = [phase EXCEPT ![v] = Created]
      # TLA        ∧ loopDevices'   = loopDevices   \ {⟨v, n⟩}
      # TLA        ∧ stagingMounts' = stagingMounts \ {⟨v, n⟩}
      # TLA        ∧ UNCHANGED ⟨owner, backingFiles, targetMounts,
      # TLA                       nodeSchedulable, nodeState, migState, migTarget,
      # TLA                       migSource, migReclaimRetain, scenarioPhase⟩
      def node_unstage_volume(req, _call)
        log_request_response(req, "node_unstage_volume") do |req_id|
          backing_file = NodeService.backing_file_path(req.volume_id)
          client = KubernetesClient.new(req_id:, logger: @logger)
          if !client.node_schedulable?(@node_id)
            # TLA \* → NodeUnstageVolumeWithMigration (see prepare_data_migration)
            prepare_data_migration(client, req_id, req.volume_id)
          end
          # loopDevices' \= {⟨v, n⟩}     \* remove_loop_device
          remove_loop_device(backing_file, req_id:)
          # stagingMounts' \= {⟨v, n⟩}   \* umount staging_path
          staging_path = req.staging_target_path
          if is_mounted?(staging_path, req_id:)
            output, ok = run_cmd("umount", "-q", staging_path, req_id:)
            unless ok
              raise "Failed to unmount #{staging_path}: #{output}"
            end
          end
          NodeUnstageVolumeResponse.new
        rescue => e
          log_and_raise(req_id, e)
        end
      end

      # TLA \* Models NodeService#node_unstage_volume when node is NOT schedulable:
      # TLA \* Calls prepare_data_migration -> retain_pv -> recreate_pvc.
      # TLA \* For the first migration: no existing old-pv-name annotation.
      # TLA NodeUnstageVolumeWithMigration(v, newNode) ==
      # TLA     ∧ phase[v] = Staged
      # TLA     ∧ owner[v] ∈ Nodes
      # TLA     ∧ migState[v] = MigNone
      # TLA     ∧ LET oldNode == owner[v] IN
      # TLA        ∧ ⟨v, oldNode⟩ ∉ targetMounts
      # TLA        ∧ nodeSchedulable[oldNode] = FALSE
      # TLA        ∧ newNode ∈ Nodes
      # TLA        ∧ newNode /= oldNode
      # TLA        ∧ nodeSchedulable[newNode] = TRUE
      # TLA        ∧ phase'         = [phase EXCEPT ![v] = Created]
      # TLA        ∧ loopDevices'   = loopDevices   \ {⟨v, oldNode⟩}
      # TLA        ∧ stagingMounts' = stagingMounts \ {⟨v, oldNode⟩}
      # TLA        ∧ migState'      = [migState  EXCEPT ![v] = MigPrepared]
      # TLA        ∧ migTarget'     = [migTarget EXCEPT ![v] = newNode]
      # TLA        ∧ migSource'     = [migSource EXCEPT ![v] = oldNode]
      # TLA        ∧ migReclaimRetain' = [migReclaimRetain EXCEPT ![v] = TRUE]
      # TLA        ∧ UNCHANGED ⟨owner, backingFiles, targetMounts, nodeSchedulable,
      # TLA                       nodeState, scenarioPhase⟩
      def prepare_data_migration(client, req_id, volume_id)
        # migReclaimRetain' = TRUE  \* retain_pv sets Retain policy
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
        pv_name = pv.dig("metadata", "name")
        begin
          pvc = client.get_pvc(pvc_namespace, pvc_name)
        rescue ObjectNotFoundError
          old_pvc_object = pv.dig("metadata", "annotations", OLD_PVC_OBJECT_ANNOTATION_KEY)
          if old_pvc_object.empty?
            raise
          end

          pvc = YAML.load(Base64.decode64(old_pvc_object))
        end
        log_with_id(req_id, "Found matching PVC for PV #{pv_name}: #{pvc}")
        pvc_uid = pvc.dig("metadata", "uid")
        pvc_deletion_timestamp = pvc.dig("metadata", "deletionTimestamp")
        trim_pvc(pvc, pv_name)
        log_with_id(req_id, "Trimmed PVC for recreation: #{pvc}")

        client.patch_resource("pv", pv_name, OLD_PVC_OBJECT_ANNOTATION_KEY, Base64.strict_encode64(YAML.dump(pvc)))

        if pvc_uid == pv_name.delete_prefix("pvc-")
          if !pvc_deletion_timestamp
            client.delete_pvc(pvc_namespace, pvc_name)
            log_with_id(req_id, "Deleted PVC #{pvc_namespace}/#{pvc_name}")
            client.remove_pvc_finalizers(pvc_namespace, pvc_name)
            log_with_id(req_id, "Removed PVC finalizers #{pvc_namespace}/#{pvc_name}")
          end
          begin
            client.create_pvc(pvc)
          rescue AlreadyExistsError
            log_with_id(req_id, "PVC already recreated by StatefulSet controller, patching migration annotation")
            client.patch_resource("pvc", pvc_name, OLD_PV_NAME_ANNOTATION_KEY, pv_name, namespace: pvc_namespace)
          else
            log_with_id(req_id, "Recreated PVC with the new spec")
          end
        else
          # PVC is recreated now.
          # At this stage we don't know whether we have created the PVC or
          # Statefulset controller has created it. We just need to make sure
          # the csi.ubicloud.com/old-pv-name annotation is set.
          client.patch_resource("pvc", pvc_name, OLD_PV_NAME_ANNOTATION_KEY, pv_name, namespace: pvc_namespace)
        end
      end

      # TLA \* Models NodeService#node_publish_volume: bind mount from staging to target.
      # TLA NodePublishVolume(v) ==
      # TLA     ∧ phase[v] = Staged
      # TLA     ∧ owner[v] ∈ Nodes
      # TLA     ∧ LET n == owner[v] IN
      # TLA        ∧ ⟨v, n⟩ ∈ stagingMounts
      # TLA        ∧ phase'        = [phase EXCEPT ![v] = Published]
      # TLA        ∧ targetMounts' = targetMounts ∪ {⟨v, n⟩}
      # TLA        ∧ UNCHANGED ⟨owner, backingFiles, loopDevices, stagingMounts,
      # TLA                       nodeSchedulable, nodeState, migState, migTarget,
      # TLA                       migSource, migReclaimRetain, scenarioPhase⟩
      def node_publish_volume(req, _call)
        log_request_response(req, "node_publish_volume") do |req_id|
          staging_path = req.staging_target_path
          target_path = req.target_path

          # targetMounts' ∪= {⟨v, n⟩}  \* mount --bind staging → target
          unless is_mounted?(target_path, req_id:)
            FileUtils.mkdir_p(target_path)
            output, ok = run_cmd("mount", "--bind", staging_path, target_path, req_id:)
            unless ok
              raise "Failed to bind mount #{staging_path} to #{target_path}: #{output}"
            end
          end

          NodePublishVolumeResponse.new
        rescue => e
          log_and_raise(req_id, e)
        end
      end

      # TLA \* Models NodeService#node_unpublish_volume: unmounts the bind mount.
      # TLA NodeUnpublishVolume(v) ==
      # TLA     ∧ phase[v] = Published
      # TLA     ∧ owner[v] ∈ Nodes
      # TLA     ∧ LET n == owner[v] IN
      # TLA        ∧ ⟨v, n⟩ ∈ targetMounts
      # TLA        ∧ phase'        = [phase EXCEPT ![v] = Staged]
      # TLA        ∧ targetMounts' = targetMounts \ {⟨v, n⟩}
      # TLA        ∧ UNCHANGED ⟨owner, backingFiles, loopDevices, stagingMounts,
      # TLA                       nodeSchedulable, nodeState, migState, migTarget,
      # TLA                       migSource, migReclaimRetain, scenarioPhase⟩
      def node_unpublish_volume(req, _call)
        log_request_response(req, "node_unpublish_volume") do |req_id|
          target_path = req.target_path

          # targetMounts' \= {⟨v, n⟩}  \* umount target_path
          if is_mounted?(target_path, req_id:)
            output, ok = run_cmd("umount", "-q", target_path, req_id:)
            unless ok
              raise "Failed to unmount #{target_path}: #{output}"
            end
          else
            log_with_id(req_id, "#{target_path} is not mounted, skipping umount")
          end

          NodeUnpublishVolumeResponse.new
        rescue => e
          log_and_raise(req_id, e)
        end
      end

      def start_mesh_connectivity_checker
        @mesh_checker = Csi::MeshConnectivityChecker.new(logger: @logger, node_id: @node_id)
        @mesh_checker.start
      end

      def shutdown!
        @mesh_checker.shutdown!
      end
    end
  end
end
