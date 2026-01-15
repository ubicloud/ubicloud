# frozen_string_literal: true

class Serializers::Project < Serializers::Base
  def self.serialize_internal(p, options = {})
    {
      id: p.ubid,
      name: p.name,
      credit: p.credit.to_f,
      discount: p.discount
    }
  end
end
