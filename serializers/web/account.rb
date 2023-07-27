# frozen_string_literal: true

class Serializers::Web::Account < Serializers::Base
  def self.base(a)
    {
      id: a.id,
      ubid: a.ubid,
      email: a.email
    }
  end

  structure(:default) do |a|
    base(a)
  end
end
