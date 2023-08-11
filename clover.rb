# frozen_string_literal: true

require_relative "model"

require "mail"
require "roda"

class Clover < Roda
  def self.freeze
    # :nocov:
    unless Config.test?
      Sequel::Model.freeze_descendents
      DB.freeze
    end
    # :nocov:
    super
  end

  route do |r|
    r.on "api" do
      r.run CloverApi
    end

    r.run CloverWeb
  end
end
