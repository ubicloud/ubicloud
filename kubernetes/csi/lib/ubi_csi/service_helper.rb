# frozen_string_literal: true

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
  end
end
