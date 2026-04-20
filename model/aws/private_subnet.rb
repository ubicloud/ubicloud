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

    # AWS reserves the first four (network, VPC router, DNS, future use)
    # and the last (broadcast) addresses of every subnet. See:
    # https://docs.aws.amazon.com/vpc/latest/userguide/subnets.html#subnet-sizing
    def aws_ipv4_reservation
      [4, 1]
    end
  end
end
