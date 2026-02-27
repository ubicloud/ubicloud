# frozen_string_literal: true

require_relative "../model"

class LocationGcpAz < Sequel::Model
  many_to_one :location, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: location_gcp_az
# Columns:
#  id          | uuid | PRIMARY KEY
#  location_id | uuid | NOT NULL
#  az          | text | NOT NULL
#  zone_name   | text | NOT NULL
# Indexes:
#  location_gcp_az_pkey                 | PRIMARY KEY btree (id)
#  location_gcp_az_location_id_az_index | UNIQUE btree (location_id, az)
# Foreign key constraints:
#  location_gcp_az_location_id_fkey | (location_id) REFERENCES location(id) ON DELETE CASCADE
