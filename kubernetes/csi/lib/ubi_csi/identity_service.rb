# frozen_string_literal: true

require "grpc"
require_relative "../csi_services_pb"

module Csi
  module V1
    class IdentityService < Identity::Service
      def get_plugin_info(request, _call)
        GetPluginInfoResponse.new(
          name: "ubi.csi.identity",
          vendor_version: "0.1.0"
        )
      end

      def get_plugin_capabilities(request, _call)
        GetPluginCapabilitiesResponse.new(
          capabilities: [
            PluginCapability.new(
              service: PluginCapability::Service.new(
                type: PluginCapability::Service::Type::CONTROLLER_SERVICE
              )
            )
          ]
        )
      end

      def probe(request, _call)
        ProbeResponse.new(
          ready: Google::Protobuf::BoolValue.new(value: true)
        )
      end
    end
  end
end
