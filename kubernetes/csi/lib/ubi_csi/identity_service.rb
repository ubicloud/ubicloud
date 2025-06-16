# frozen_string_literal: true

require "grpc"
require_relative "service_helper"
require_relative "../csi_services_pb"

module Csi
  module V1
    class IdentityService < Identity::Service
      include Csi::ServiceHelper

      def initialize(logger:)
        @logger = logger
      end

      def get_plugin_info(req, _call)
        log_request_response(req, "get_plugin_info") do |req_id|
          GetPluginInfoResponse.new(
            name: "csi.ubicloud.com",
            vendor_version: Csi::VERSION
          )
        end
      end

      def get_plugin_capabilities(req, _call)
        log_request_response(req, "get_plugin_capabilities") do |req_id|
          GetPluginCapabilitiesResponse.new(
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
        end
      end

      def probe(req, _call)
        log_request_response(req, "probe") do |req_id|
          ProbeResponse.new(
            ready: Google::Protobuf::BoolValue.new(value: true)
          )
        end
      end
    end
  end
end
