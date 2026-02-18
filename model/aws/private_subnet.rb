# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Aws
    private

    def aws_connect_subnet(subnet)
      ConnectedSubnet.create(subnet_hash(subnet))
    end

    def aws_disconnect_subnet(subnet)
      ConnectedSubnet.where(subnet_hash(subnet)).destroy
    end
  end
end
