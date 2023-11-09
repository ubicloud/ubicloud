# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :private_subnet

  include ResourceMethods

  def ip6?
    ip.to_s.include?(":")
  end
end
