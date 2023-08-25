# frozen_string_literal: true

require_relative "../model"

class AccessTag < Sequel::Model
  many_to_one :project
  one_to_many :applied_tags

  plugin :association_dependencies, applied_tags: :destroy

  include ResourceMethods
end
