# frozen_string_literal: true

class Serializers::Api::Firewall < Serializers::Base
  def self.serialize_internal(firewall, options = {})
    base = {
      id: firewall.ubid,
      name: firewall.name,
      description: firewall.description,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Common::FirewallRule.serialize(fw) }
    }

    if options[:detailed]
      base[:private_subnets] = firewall.private_subnets.map { |ps| Serializers::Api::PrivateSubnet.serialize(ps) }
    end

    base
  end
end
