# frozen_string_literal: true

class Serializers::PrivateSubnet < Serializers::Base
  def self.serialize_internal(ps, options = {})
    base = {
      id: ps.ubid,
      name: ps.name,
      state: ps.display_state,
      location: ps.display_location,
      net4: ps.net4.to_s,
      net6: ps.net6.to_s,
      firewalls: Serializers::Firewall.serialize(ps.firewalls),
      nics: Serializers::Nic.serialize(ps.nics)
    }

    if options[:include_path]
      base[:path] = ps.path
    end

    base
  end
end
