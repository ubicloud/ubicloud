# frozen_string_literal: true

class Serializers::Api::PrivateSubnet < Serializers::Base
  def self.base(ps)
    {
      id: ps.ubid,
      name: ps.name,
      state: ps.display_state,
      location: ps.display_location,
      net4: ps.net4.to_s,
      net6: ps.net6.to_s,
      nics: Serializers::Api::Nic.serialize(ps.nics)
    }
  end

  structure(:default) do |ps|
    base(ps)
  end
end
