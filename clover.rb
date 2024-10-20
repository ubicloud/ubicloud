# frozen_string_literal: true

require_relative "model"

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
    if r.host.start_with?("api.")
      r.run CloverApi
    end

    # To make test and development easier
    # :nocov:
    unless Config.production?
      r.on "api" do
        r.run CloverApi
      end
    end
    # :nocov:

    r.on "runtime" do
      r.run CloverRuntime
    end

    r.run CloverWeb
  end
end
