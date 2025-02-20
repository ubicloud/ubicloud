# frozen_string_literal: true

require_relative "../model"

class ProviderLocation < Sequel::Model
  include ResourceMethods
end

# Table: provider_location
# Columns:
#  id            | uuid    | PRIMARY KEY
#  display_name  | text    | NOT NULL
#  internal_name | text    | NOT NULL
#  ui_name       | text    | NOT NULL
#  visible       | boolean | NOT NULL
#  provider_name | text    | NOT NULL
# Indexes:
#  provider_location_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  provider_location_provider_name_fkey | (provider_name) REFERENCES provider_name(name)
