# frozen_string_literal: true

class Serializers::Common::Project < Serializers::Base
  def self.serialize_internal(p, options = {})
    base = {
      id: p.ubid,
      name: p.name,
      credit: p.credit.to_f,
      discount: p.discount
    }

    if options[:include_path]
      base[:path] = p.path
    end

    base
  end
end
