# frozen_string_literal: true

class Serializers::AccessPolicy < Serializers::Base
  def self.serialize_internal(ap, options = {})
    {
      id: ap.id,
      ubid: ap.ubid,
      name: ap.name,
      body: ap.body.to_json
    }
  end
end
