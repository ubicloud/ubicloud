# frozen_string_literal: true

class Provider
  attr_reader :name, :display_name, :locations

  HETZNER = "hetzner"
  DATAPACKET = "dp"

  Location = Struct.new(:name, :display_name)

  def initialize(name, display_name, locations)
    @name = name
    @display_name = display_name
    @locations = locations.map { |args| Location.new(*args) }.freeze
  end
end
