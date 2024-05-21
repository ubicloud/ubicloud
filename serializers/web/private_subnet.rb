# frozen_string_literal: true

class Serializers::Web::PrivateSubnet < Serializers::Base
  def self.serialize_internal(ps, options = {})
    base = {
      id: ps.id,
      ubid: ps.ubid,
      path: ps.path,
      name: ps.name,
      state: ps.display_state,
      location: ps.display_location,
      net4: ps.net4.to_s,
      net6: ps.net6.to_s
    }

    if options[:detailed]
      base[:attached_firewalls] = ps.firewalls.map { |f| Serializers::Web::Firewall.serialize(f) }
    end

    base
  end
end
