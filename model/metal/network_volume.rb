# frozen_string_literal: true

class NetworkVolume < Sequel::Model
  module Metal
    private

    def metal_provider_config
      raise "network volumes are not supported on metal"
    end
  end
end
