# frozen_string_literal: true

require "grpc"
require "logger"
require_relative "../csi_services_pb"

module Csi
  module V1
    class IdentityService < Identity::Service
      LOGGER = Logger.new($stdout)

      def log_with_id(id, message)
        LOGGER.info("[req_id=#{id}] #{message}")
      end

      def get_plugin_info(request, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "get_plugin_info request: #{request.inspect}")
        resp = GetPluginInfoResponse.new(
          name: "csi.ubicloud.com",
          vendor_version: "0.1.0"
        )
        log_with_id(req_id, "get_plugin_info response: #{resp.inspect}")
        resp
      end

      def get_plugin_capabilities(request, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "get_plugin_capabilities request: #{request.inspect}")
        resp = GetPluginCapabilitiesResponse.new(
          capabilities: [
            PluginCapability.new(
              service: PluginCapability::Service.new(
                type: PluginCapability::Service::Type::CONTROLLER_SERVICE
              )
            ),
            PluginCapability.new(
              service: PluginCapability::Service.new(
                type: PluginCapability::Service::Type::VOLUME_ACCESSIBILITY_CONSTRAINTS
              )
            )
          ]
        )
        log_with_id(req_id, "get_plugin_capabilities response: #{resp.inspect}")
        resp
      end

      def probe(request, _call)
        req_id = SecureRandom.uuid
        log_with_id(req_id, "probe request: #{request.inspect}")
        resp = ProbeResponse.new(
          ready: Google::Protobuf::BoolValue.new(value: true)
        )
        log_with_id(req_id, "probe response: #{resp.inspect}")
        resp
      end
    end
  end
end
