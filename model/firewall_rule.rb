# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :private_subnet

  include ResourceMethods
end
