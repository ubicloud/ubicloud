# frozen_string_literal: true

class Serializers::Firewall < Serializers::Base
  def self.serialize_internal(firewall, options = {})
    base = {
      id: firewall.ubid,
      name: firewall.name,
      description: firewall.description,
      location: firewall.display_location,
      firewall_rules: Serializers::FirewallRule.serialize(firewall.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s })
    }

    if options[:include_path]
      base[:path] = firewall.path
    end

    if options[:detailed]
      base[:private_subnets] = Serializers::PrivateSubnet.serialize(firewall.private_subnets)
    end

    base
  end
end
