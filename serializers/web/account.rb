# frozen_string_literal: true

require_relative "../base"

class Serializers::Web::Account < Serializers::Base
  def self.base(a)
    {
      id: a.id,
      ulid: a.ulid,
      email: a.email
    }
  end

  structure(:default) do |a|
    base(a)
  end
end
