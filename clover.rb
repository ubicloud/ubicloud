# frozen_string_literal: true

require_relative "model"

require "mail"
require "roda"
require "drb/drb"

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
    # TODO: Get the list of location:uri map from config
    drb1 = DRbObject.new_with_uri("druby://localhost:12345")
    ResourceManager.add_remote("hetzner-fsn1", drb1)

    r.on "api" do
      r.run CloverApi
    end

    r.run CloverWeb
  end
end
