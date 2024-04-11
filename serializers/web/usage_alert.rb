# frozen_string_literal: true

class Serializers::Web::UsageAlert < Serializers::Base
  def self.base(ua)
    {
      ubid: ua.ubid,
      name: ua.name,
      limit: ua.limit,
      email: ua.user.email
    }
  end

  structure(:default) do |ua|
    base(ua)
  end
end
