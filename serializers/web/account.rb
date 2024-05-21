# frozen_string_literal: true

class Serializers::Web::Account < Serializers::Base
  def self.serialize_internal(a, options = {})
    {
      id: a.id,
      ubid: a.ubid,
      email: a.email
    }
  end
end
