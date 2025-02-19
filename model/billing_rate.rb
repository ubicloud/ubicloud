# frozen_string_literal: true

require_relative "../model"

class BillingRate < Sequel::Model
  include ResourceMethods
  many_to_one :provider_location, class: :ProviderLocation
end
