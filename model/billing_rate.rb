# frozen_string_literal: true

require_relative "../model"

class BillingRate < Sequel::Model
  include ResourceMethods

  def self.from_resource_properties(resource_type, resource_family, location)
    BillingRate.where(resource_type: resource_type, resource_family: resource_family, location: location).first
  end
end
