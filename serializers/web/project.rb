# frozen_string_literal: true

class Serializers::Web::Project < Serializers::Base
  def self.base(p)
    {
      id: p.id,
      ubid: p.ubid,
      path: p.path,
      name: p.name,
      provider: Option::Providers[p.provider]
    }
  end

  structure(:default) do |p|
    base(p)
  end
end
