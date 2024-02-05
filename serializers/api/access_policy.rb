# frozen_string_literal: true

class Serializers::Api::AccessPolicy < Serializers::Base
  def self.base(ap)
    {
      ubid: ap.ubid,
      name: ap.name,
      body: ap.body.to_json
    }
  end

  structure(:default) do |ap|
    base(ap)
  end
end
