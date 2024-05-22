# frozen_string_literal: true

class Serializers::UsageAlert < Serializers::Base
  def self.serialize_internal(ua, options = {})
    {
      ubid: ua.ubid,
      name: ua.name,
      limit: ua.limit,
      email: ua.user.email
    }
  end
end
