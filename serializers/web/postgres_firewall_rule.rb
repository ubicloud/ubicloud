# frozen_string_literal: true

class Serializers::Web::PostgresFirewallRule < Serializers::Base
  def self.base(postgres_firewall_rule)
    {
      id: postgres_firewall_rule.id,
      ubid: postgres_firewall_rule.ubid,
      cidr: postgres_firewall_rule.cidr
    }
  end

  structure(:default) do |postgres_firewall_rule|
    base(postgres_firewall_rule)
  end
end
