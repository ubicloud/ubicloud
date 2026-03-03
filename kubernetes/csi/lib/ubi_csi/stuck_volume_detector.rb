# frozen_string_literal: true

require "yaml"
require "base64"
require_relative "kubernetes_client"
require_relative "service_helper"

module Csi
  class StuckVolumeDetector
    include ServiceHelper

    CHECK_INTERVAL = 15

    def initialize(logger:)
      @logger = logger
      @queue = Queue.new
      @shutdown = false
    end

    def start
      spawn_check_thread
      @logger.info("[StuckVolumeDetector] Started stuck volume detector")
    end

    def spawn_check_thread
      @thread = Thread.new do
        until @shutdown
          check_stuck_volumes
          @queue.pop(timeout: CHECK_INTERVAL)
        end
      end
    end

    def shutdown!
      @shutdown = true
      @queue.close
      @thread&.join
    end

    def check_stuck_volumes
      client = KubernetesClient.new(req_id: "stuck-vol-check", logger: @logger, log_level: :debug)

      pvcs = YAML.safe_load(client.run_kubectl("get", "pvc", "--all-namespaces", "-oyaml"))["items"]
      pvs_by_name = YAML.safe_load(client.run_kubectl("get", "pv", "-oyaml"))["items"].to_h { |pv| [pv.dig("metadata", "name"), pv] }

      pvcs.each do |pvc|
        old_pv_name = pvc.dig("metadata", "annotations", OLD_PV_NAME_ANNOTATION_KEY)
        next unless old_pv_name

        bound_pv_name = pvc.dig("spec", "volumeName")
        next unless bound_pv_name

        bound_pv = pvs_by_name[bound_pv_name]
        next unless bound_pv

        pv_node = client.extract_node_from_pv(bound_pv)
        next unless pv_node
        next if client.node_schedulable?(pv_node)

        pvc_namespace = pvc.dig("metadata", "namespace")
        pvc_name = pvc.dig("metadata", "name")
        @logger.info("[StuckVolumeDetector] Detected stuck PVC #{pvc_namespace}/#{pvc_name} bound to PV #{bound_pv_name} on cordoned node #{pv_node}")

        recover_stuck_pvc(client, pvc, bound_pv, old_pv_name)
      rescue => e
        @logger.error("[StuckVolumeDetector] Error processing PVC: #{e.message}\n#{e.backtrace.join("\n")}")
      end
    rescue => e
      @logger.error("[StuckVolumeDetector] Error checking stuck volumes: #{e.message}\n#{e.backtrace.join("\n")}")
    end

    def recover_stuck_pvc(client, pvc, intermediate_pv, source_pv_name)
      intermediate_pv_name = intermediate_pv.dig("metadata", "name")
      pvc_namespace = pvc.dig("metadata", "namespace")
      pvc_name = pvc.dig("metadata", "name")

      # Roll intermediate PV to Delete — it has incomplete data
      if intermediate_pv.dig("spec", "persistentVolumeReclaimPolicy") != "Delete"
        intermediate_pv["spec"]["persistentVolumeReclaimPolicy"] = "Delete"
        client.update_pv(intermediate_pv)
        @logger.info("[StuckVolumeDetector] Rolled back intermediate PV #{intermediate_pv_name} to Delete")
      end

      # Reset retry count on source PV so the new target gets a fresh budget
      source_pv = client.get_pv(source_pv_name)
      if source_pv.dig("metadata", "annotations", MIGRATION_RETRY_COUNT_ANNOTATION_KEY)
        client.patch_resource("pv", source_pv_name, MIGRATION_RETRY_COUNT_ANNOTATION_KEY, nil)
        @logger.info("[StuckVolumeDetector] Reset retry count on source PV #{source_pv_name}")
      end

      pvc_uid = pvc.dig("metadata", "uid")
      pvc_deletion_timestamp = pvc.dig("metadata", "deletionTimestamp")
      trimmed_pvc = trim_pvc(pvc, source_pv_name)
      client.patch_resource("pv", source_pv_name, OLD_PVC_OBJECT_ANNOTATION_KEY,
        Base64.strict_encode64(YAML.dump(trimmed_pvc)))

      if pvc_uid == intermediate_pv_name.delete_prefix("pvc-")
        unless pvc_deletion_timestamp
          client.delete_pvc(pvc_namespace, pvc_name)
          @logger.info("[StuckVolumeDetector] Deleted PVC #{pvc_namespace}/#{pvc_name}")
          client.remove_pvc_finalizers(pvc_namespace, pvc_name)
          @logger.info("[StuckVolumeDetector] Removed PVC finalizers #{pvc_namespace}/#{pvc_name}")
        end
        begin
          client.create_pvc(trimmed_pvc)
        rescue => e
          raise unless e.message.include?("AlreadyExists")
          # StatefulSet controller recreated PVC before us, just patch the annotation
          client.patch_resource("pvc", pvc_name, OLD_PV_NAME_ANNOTATION_KEY, source_pv_name, namespace: pvc_namespace)
          @logger.info("[StuckVolumeDetector] PVC already recreated by controller, patched old-pv-name annotation on #{pvc_namespace}/#{pvc_name}")
        else
          @logger.info("[StuckVolumeDetector] Recreated PVC #{pvc_namespace}/#{pvc_name}")
        end
      else
        # PVC was already recreated by StatefulSet controller, just patch the annotation
        client.patch_resource("pvc", pvc_name, OLD_PV_NAME_ANNOTATION_KEY, source_pv_name, namespace: pvc_namespace)
        @logger.info("[StuckVolumeDetector] Patched old-pv-name annotation on PVC #{pvc_namespace}/#{pvc_name}")
      end
    end
  end
end
