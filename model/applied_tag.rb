# frozen_string_literal: true

require_relative "../model"

class AppliedTag < Sequel::Model
  many_to_one :access_tag
end
