# frozen_string_literal: true

class Serializers::PrivateLocation < Serializers::Base
  def self.serialize_internal(location, options = {})
    {
      id: location.ubid,
      name: location.name,
      ui_name: location.ui_name,
      provider: location.provider,
      path: location.path
    }
  end
end
