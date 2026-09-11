# frozen_string_literal: true

class Serializers::Project < Serializers::Base
  def self.serialize_internal(p, options = {})
    {
      id: p.ubid,
      name: p.name,
    }
  end
end
