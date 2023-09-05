# frozen_string_literal: true

module CloudHypervisor
  VERSION = "31.0"
  FIRMWARE_VERSION = "edk2-stable202302"

  def self.firmware
    "/opt/fw/#{FIRMWARE_VERSION}/x64/CLOUDHV.fd"
  end
end
