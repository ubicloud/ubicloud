# frozen_string_literal: true

require_relative "model"

require "roda"

class CloverAdmin < Roda
  route do |r|
    r.env["HTTP_HOST"]
  end
end
