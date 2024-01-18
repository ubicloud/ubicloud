# frozen_string_literal: true

class Serializers::Web::Firewall < Serializers::Base
  def self.base(firewall)
    {
      id: firewall.id,
      name: firewall.name,
      description: firewall.description,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Web::FirewallRule.serialize(fw) }
    }
  end

  structure(:default) do |firewall|
    base(firewall)
  end
end
