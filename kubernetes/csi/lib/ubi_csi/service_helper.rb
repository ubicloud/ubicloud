# frozen_string_literal: true

require "open3"
require "securerandom"

module Csi
  module ServiceHelper
    OLD_PV_NAME_ANNOTATION_KEY = "csi.ubicloud.com/old-pv-name"
    OLD_PVC_OBJECT_ANNOTATION_KEY = "csi.ubicloud.com/old-pvc-object"
    MIGRATION_RETRY_COUNT_ANNOTATION_KEY = "csi.ubicloud.com/migration-retry-count"

    def log_with_id(req_id, message)
      @logger.send(@log_level || :info, "[req_id=#{req_id}] #{message}")
    end

    def log_request_response(req, type)
      raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) unless req

      req_id = SecureRandom.uuid
      log_with_id(req_id, "#{type} request: #{req.inspect}")
      resp = yield(req_id)
      log_with_id(req_id, "#{type} response: #{resp.inspect}")
      resp
    end

    def log_run_cmd(req_id, cmd, **kwargs)
      log_with_id(req_id, "Running command: #{cmd.join(" ")} with #{kwargs}")
      yield
    end

    def run_cmd(*cmd, req_id:, log: true, **kwargs)
      run = -> { Open3.capture2e(*cmd, **kwargs) }
      log ? log_run_cmd(req_id, cmd, **kwargs, &run) : run.call
    end

    def log_and_raise(req_id, exception)
      log_with_id(req_id, "#{exception.class}: #{exception.message}\n#{exception.backtrace.join("\n")}")
      raise GRPC::Internal.new(exception.message)
    end

    def trim_pvc(pvc, pv_name)
      pvc["metadata"]["annotations"] ||= {}
      %W[#{OLD_PVC_OBJECT_ANNOTATION_KEY} volume.kubernetes.io/selected-node pv.kubernetes.io/bind-completed].each do |key|
        pvc["metadata"]["annotations"].delete(key)
      end
      %w[resourceVersion uid creationTimestamp deletionTimestamp deletionGracePeriodSeconds].each do |key|
        pvc["metadata"].delete(key)
      end
      pvc["spec"].delete("volumeName")
      pvc.delete("status")
      # ||= preserves the original source PV name during chained migrations.
      # Without it, each chained migration would overwrite the annotation with
      # the intermediate PV name, causing rsync to copy from a node with
      # incomplete data instead of the true data source.
      pvc["metadata"]["annotations"][OLD_PV_NAME_ANNOTATION_KEY] ||= pv_name
      pvc
    end
  end
end
