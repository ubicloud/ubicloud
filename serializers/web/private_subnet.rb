# frozen_string_literal: true

class Serializers::Web::PrivateSubnet < Serializers::Base
  def self.base(ps)
    {
      id: ps.id,
      ubid: ps.ubid,
      path: ps.path,
      name: ps.name,
      state: ps.display_state,
      location: ps.display_location,
      net4: ps.net4.to_s,
      net6: ps.net6.to_s
    }
  end

  structure(:default) do |ps|
    base(ps)
  end

  structure(:detailed) do |ps|
    base(ps).merge(
      attached_firewalls: ps.firewalls.map { |f| Serializers::Web::Firewall.serialize(f) }
    )
  end
end
