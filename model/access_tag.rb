# frozen_string_literal: true

require_relative "../model"

class AccessTag < Sequel::Model
  many_to_one :project
  one_to_many :applied_tags

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ACCESS_TAG
  end
end
