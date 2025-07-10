# frozen_string_literal: true

require "open3"
require "securerandom"

module Csi
  module ServiceHelper
    def log_with_id(req_id, message)
      @logger.info("[req_id=#{req_id}] #{message}")
    end

    def log_request_response(req, type)
      raise GRPC::InvalidArgument.new("Request cannot be nil", GRPC::Core::StatusCodes::INVALID_ARGUMENT) unless req
      req_id = SecureRandom.uuid
      log_with_id(req_id, "#{type} request: #{req.inspect}")
      resp = yield(req_id)
      log_with_id(req_id, "#{type} response: #{resp.inspect}")
      resp
    end

    def log_run_cmd(req_id, cmd)
      log_with_id(req_id, "Running command: #{cmd.join(" ")}")
      yield
    end

    def run_cmd(*cmd, req_id:, **kwargs)
      log_run_cmd(req_id, cmd) do
        Open3.capture2e(*cmd, **kwargs)
      end
    end
  end
end
