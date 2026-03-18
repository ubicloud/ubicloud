# frozen_string_literal: true

require_relative "../model"

class LocationAwsAz < Sequel::Model
  set_primary_key :id

  many_to_one :location, read_only: true, is_used: true
  plugin ResourceMethods
end

# Table: location_aws_az
# Columns:
#  id          | uuid |
#  location_id | uuid |
#  az          | text |
#  zone_id     | text |
