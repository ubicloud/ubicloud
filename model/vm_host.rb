# frozen_string_literal: true

require_relative "../model"

class VmHost < Sequel::Model
  one_to_one :strand, key: :id
end
