# frozen_string_literal: true

class NetworkVolume < Sequel::Model
  module Aws
    private

    def aws_provider_config = aws_volume
  end
end
