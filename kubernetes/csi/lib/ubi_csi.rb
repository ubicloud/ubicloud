# frozen_string_literal: true

require "grpc"
require "csi_pb"
require "csi_services_pb"

module Csi
  VERSION = "0.1.0"
end

require_relative "ubi_csi/identity_service"
require_relative "ubi_csi/controller_service"
