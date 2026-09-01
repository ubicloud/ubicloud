# frozen_string_literal: true

class NetworkVolume < Sequel::Model
  module Gcp
    private

    def gcp_provider_config = gcp_volume
  end
end
