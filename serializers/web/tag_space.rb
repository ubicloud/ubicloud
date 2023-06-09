# frozen_string_literal: true

require_relative "../base"

class Serializers::Web::TagSpace < Serializers::Base
  def self.base(tg)
    {
      id: tg.id,
      ulid: tg.ulid,
      path: tg.path,
      name: tg.name
    }
  end

  structure(:default) do |tg|
    base(tg)
  end
end
