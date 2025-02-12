# frozen_string_literal: true

require_relative "../model"

class Provider < Sequel::Model
  include ResourceMethods
  one_to_many :locations, class: :ProviderLocation

  def self.ubid_type
    UBID::TYPE_ETC
  end
end

# Table: provider
# Columns:
#  display_name  | text | NOT NULL
#  internal_name | text | NOT NULL
#  id            | uuid | PRIMARY KEY
# Indexes:
#  provider_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  provider_location | provider_location_provider_id_fkey | (provider_id) REFERENCES provider(id)
