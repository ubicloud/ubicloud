# frozen_string_literal: true

require_relative "model"

require "mail"
require "roda"

class Clover < Roda
  route do |r|
    r.on "api" do
      r.run CloverApi
    end

    r.run CloverWeb
  end
end
