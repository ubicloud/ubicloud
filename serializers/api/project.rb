# frozen_string_literal: true

require_relative "../base"

class Serializers::Api::Project < Serializers::Base
  def self.base(p)
    {
      id: p.ulid,
      name: p.name
    }
  end

  structure(:default) do |p|
    base(p)
  end
end
