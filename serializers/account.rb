# frozen_string_literal: true

require_relative "base"

class Serializers::Account < Serializers::Base
  def self.serialize_internal(a, options = {})
    {
      id: a.id,
      ubid: a.ubid,
      email: a.email
    }
  end
end
