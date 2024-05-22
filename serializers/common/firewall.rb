# frozen_string_literal: true

class Serializers::Common::Firewall < Serializers::Base
  def self.serialize_internal(firewall, options = {})
    base = {
      id: firewall.ubid,
      name: firewall.name,
      description: firewall.description,
      firewall_rules: firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Common::FirewallRule.serialize(fw) }
    }

    if options[:include_path]
      base[:path] = firewall.path
    end

    if options[:detailed]
      base[:private_subnets] = firewall.private_subnets.map { |ps| Serializers::Common::PrivateSubnet.serialize(ps) }
    end

    base
  end
end
