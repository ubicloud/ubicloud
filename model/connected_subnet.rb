# frozen_string_literal: true

require_relative "../model"

class ConnectedSubnet < Sequel::Model
  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end
end
