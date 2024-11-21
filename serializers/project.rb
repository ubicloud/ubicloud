# frozen_string_literal: true

class Serializers::Project < Serializers::Base
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

    if options[:web]
      base[:feature_flags] = p.feature_flags
    end

    base
  end
end
