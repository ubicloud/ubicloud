# frozen_string_literal: true

require_relative "../model"

class SubnetPeer < Sequel::Model
  many_to_one :provider_subnet, key: :provider_subnet_id, class: :PrivateSubnet
  many_to_one :peer_subnet, key: :peer_subnet_id, class: :PrivateSubnet

  include ResourceMethods

  include SemaphoreMethods
  semaphore :destroy
end
