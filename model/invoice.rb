# frozen_string_literal: true

require_relative "../model"

class Invoice < Sequel::Model
  include ResourceMethods
end
