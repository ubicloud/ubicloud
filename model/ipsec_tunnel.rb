# frozen_string_literal: true

require_relative "../model"

class IpsecTunnel < Sequel::Model
  many_to_one :vm

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_IPSEC_TUNNEL
  end
end
