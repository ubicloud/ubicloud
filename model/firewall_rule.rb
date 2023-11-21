# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :private_subnet
  many_to_one :subnet_peer

  include ResourceMethods

  def ip6?
    ip.to_s.include?(":")
  end
end
