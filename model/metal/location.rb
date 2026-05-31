# frozen_string_literal: true

class Location < Sequel::Model
  module Metal
    private

    def metal_azs
      raise "azs is only valid for aws locations"
    end

    def metal_scheduled_maintenance_events
      {}
    end
  end
end
