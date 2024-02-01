# frozen_string_literal: true

class Serializers::Web::FirewallRule < Serializers::Base
  def self.base(firewall_rule)
    {
      id: firewall_rule.id,
      ubid: firewall_rule.ubid,
      cidr: firewall_rule.cidr,
      port_range: firewall_rule.port_range&.begin ? "#{firewall_rule.port_range.begin}..#{firewall_rule.port_range.end - 1}" : "0..65535"
    }
  end

  structure(:default) do |firewall_rule|
    base(firewall_rule)
  end
end
