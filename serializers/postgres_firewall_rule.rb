# frozen_string_literal: true

class Serializers::PostgresFirewallRule < Serializers::Base
  def self.serialize_internal(firewall_rule, options = {})
    {
      id: firewall_rule.ubid,
      cidr: firewall_rule.cidr,
      port: firewall_rule.is_a?(PostgresFirewallRule) ? 5432 : firewall_rule.port_range.begin,
      description: firewall_rule.description || ""
    }
  end
end
