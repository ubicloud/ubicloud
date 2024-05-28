# frozen_string_literal: true

class Serializers::Web::Project < Serializers::Base
  def self.serialize_internal(p, options = {})
    {
      id: p.id,
      ubid: p.ubid,
      path: p.path,
      name: p.name,
      credit: p.credit.to_f,
      discount: p.discount
    }
  end
end
