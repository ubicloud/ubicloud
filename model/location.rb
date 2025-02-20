# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  include ResourceMethods
end

# Table: location
# Columns:
#  id           | uuid    | PRIMARY KEY
#  display_name | text    | NOT NULL
#  name         | text    | NOT NULL
#  ui_name      | text    | NOT NULL
#  visible      | boolean | NOT NULL
#  provider     | text    | NOT NULL
# Indexes:
#  location_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_provider_fkey | (provider) REFERENCES provider(name)
