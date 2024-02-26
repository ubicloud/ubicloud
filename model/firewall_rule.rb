# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :firewall, key: :firewall_id

  include ResourceMethods

  def ip6?
    cidr.to_s.include?(":")
  end
end
