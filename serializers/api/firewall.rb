# frozen_string_literal: true

class Serializers::Api::Firewall < Serializers::Base
  def self.base(firewall)
    {
      id: firewall.ubid,
      name: firewall.name,
      description: firewall.description,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Api::FirewallRule.serialize(fw) }
    }
  end

  structure(:default) do |firewall|
    base(firewall)
  end
end
