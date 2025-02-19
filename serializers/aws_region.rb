# frozen_string_literal: true

class Serializers::AwsRegion < Serializers::Base
  def self.serialize_internal(region, options = {})
    {
      id: region.id,
      location: region.location
    }
  end
end
