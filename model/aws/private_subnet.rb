# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Aws
    private

    def aws_connect_subnet(subnet)
      raise "Connected subnets are not supported for AWS"
    end

    def aws_disconnect_subnet(subnet)
      raise "Connected subnets are not supported for AWS"
    end
  end
end
