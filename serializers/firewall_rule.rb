# frozen_string_literal: true

class Serializers::FirewallRule < Serializers::Base
  def self.serialize_internal(firewall_rule, options = {})
    {
      id: firewall_rule.ubid,
      cidr: firewall_rule.cidr,
      port_range: firewall_rule.display_port_range,
      description: firewall_rule.description || ""
    }
  end
end
