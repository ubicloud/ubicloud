# frozen_string_literal: true

class Serializers::Web::Firewall < Serializers::Base
  def self.base(firewall)
    {
      ubid: firewall.ubid,
      id: firewall.id,
      name: firewall.name,
      description: firewall.description,
      path: firewall.path,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Common::FirewallRule.serialize(fw) }
    }
  end

  structure(:default) do |firewall|
    base(firewall)
  end

  structure(:detailed) do |firewall|
    base(firewall).merge(
      private_subnets: firewall.private_subnets.map { |ps| Serializers::Web::PrivateSubnet.serialize(ps) }
    )
  end
end
