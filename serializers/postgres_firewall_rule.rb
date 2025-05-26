# frozen_string_literal: true

class Serializers::PostgresFirewallRule < Serializers::Base
  def self.serialize_internal(postgres_firewall_rule, options = {})
    {
      id: postgres_firewall_rule.ubid,
      cidr: postgres_firewall_rule.cidr,
      description: postgres_firewall_rule.description || ""
    }
  end
end
