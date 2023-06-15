# frozen_string_literal: true

require_relative "../base"

class Serializers::Web::Project < Serializers::Base
  def self.base(p)
    {
      id: p.id,
      ulid: p.ulid,
      path: p.path,
      name: p.name
    }
  end

  structure(:default) do |p|
    base(p)
  end
end
