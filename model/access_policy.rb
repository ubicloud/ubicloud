# frozen_string_literal: true

require_relative "../model"

class AccessPolicy < Sequel::Model
  many_to_one :tag_space

  include ResourceMethods
end
