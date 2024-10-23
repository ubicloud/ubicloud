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
    subdomain = r.host.split(".").first
    if subdomain == "api"
      r.run CloverApi
    end

    r.on "runtime" do
      r.run CloverRuntime
    end

    r.run CloverWeb
  end
end
