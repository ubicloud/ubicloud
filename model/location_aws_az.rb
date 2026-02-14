# frozen_string_literal: true

require_relative "../model"

class LocationAwsAz < Sequel::Model
  many_to_one :location, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: location_aws_az
# Columns:
#  id          | uuid | PRIMARY KEY
#  location_id | uuid | NOT NULL
#  az          | text | NOT NULL
#  zone_id     | text | NOT NULL
# Indexes:
#  location_aws_az_pkey                      | PRIMARY KEY btree (id)
#  location_aws_az_location_id_zone_id_index | UNIQUE btree (location_id, zone_id)
# Foreign key constraints:
#  location_aws_az_location_id_fkey | (location_id) REFERENCES location(id) ON DELETE CASCADE
# Referenced By:
#  aws_subnet | aws_subnet_location_aws_az_id_fkey | (location_aws_az_id) REFERENCES location_aws_az(id)
