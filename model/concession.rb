# frozen_string_literal: true

require_relative "../model"

class Concession < Sequel::Model
  many_to_one :project

  include ResourceMethods
end
