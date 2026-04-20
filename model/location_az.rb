# frozen_string_literal: true

require_relative "../model"

class LocationAz < Sequel::Model
  many_to_one :location, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: location_az
# Columns:
#  id          | uuid | PRIMARY KEY
#  location_id | uuid | NOT NULL
#  az          | text | NOT NULL
#  zone_id     | text |
# Indexes:
#  location_aws_az_pkey             | PRIMARY KEY btree (id)
#  location_az_location_id_az_index | UNIQUE btree (location_id, az)
# Foreign key constraints:
#  location_aws_az_location_id_fkey | (location_id) REFERENCES location(id) ON DELETE CASCADE
# Referenced By:
#  aws_subnet | aws_subnet_location_aws_az_id_fkey | (location_aws_az_id) REFERENCES location_az(id)
