# frozen_string_literal: true

require_relative "../model"

class IpsecTunnel < Sequel::Model
  many_to_one :vm

  include ResourceMethods
end
