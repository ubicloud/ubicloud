# frozen_string_literal: true

require_relative "../model"

class AccessTag < Sequel::Model
  many_to_one :tag_space
  one_to_many :applied_tags
end
