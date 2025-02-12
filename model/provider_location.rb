# frozen_string_literal: true

require_relative "../model"

class ProviderLocation < Sequel::Model
  include ResourceMethods
  many_to_one :provider, class: :Provider

  def self.ubid_type
    UBID::TYPE_ETC
  end
end

# Table: provider_location
# Columns:
#  display_name  | text    | NOT NULL
#  internal_name | text    | NOT NULL
#  ui_name       | text    | NOT NULL
#  visible       | boolean | NOT NULL
#  id            | uuid    | PRIMARY KEY
#  provider_id   | uuid    | NOT NULL
# Indexes:
#  provider_location_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  provider_location_provider_id_fkey | (provider_id) REFERENCES provider(id)
