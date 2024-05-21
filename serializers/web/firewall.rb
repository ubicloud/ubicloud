# frozen_string_literal: true

class Serializers::Web::Firewall < Serializers::Base
  def self.serialize_internal(firewall, options = {})
    base = {
      ubid: firewall.ubid,
      id: firewall.id,
      name: firewall.name,
      description: firewall.description,
      path: firewall.path,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Common::FirewallRule.serialize(fw) }
    }

    if options[:detailed]
      base[:private_subnets] = firewall.private_subnets.map { |ps| Serializers::Web::PrivateSubnet.serialize(ps) }
    end

    base
  end
end
