# frozen_string_literal: true

class Serializers::Web::AccessPolicy < Serializers::Base
  def self.base(ap)
    ap.transform_to_names
    {
      id: ap.id,
      ubid: ap.ubid,
      name: ap.name,
      body: ap.body.to_json
    }
  end

  structure(:default) do |ap|
    base(ap)
  end
end
