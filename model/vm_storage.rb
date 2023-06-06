# frozen_string_literal: true

require_relative "../model"

class VmStorage < Sequel::Model
  many_to_one :vm
end
