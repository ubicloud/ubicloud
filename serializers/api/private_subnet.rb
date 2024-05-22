# frozen_string_literal: true

class Serializers::Api::PrivateSubnet < Serializers::Base
  def self.serialize_internal(ps, options = {})
    {
      id: ps.ubid,
      name: ps.name,
      state: ps.display_state,
      location: ps.display_location,
      net4: ps.net4.to_s,
      net6: ps.net6.to_s,
      firewalls: Serializers::Common::Firewall.serialize(ps.firewalls),
      nics: Serializers::Common::Nic.serialize(ps.nics)
    }
  end
end
