# frozen_string_literal: true

require_relative "../model"

class ProviderIpRange < Sequel::Model
  plugin ResourceMethods, etc_type: true
  plugin :update_or_create
end

# Table: provider_ip_range
# Columns:
#  id           | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  location_id  | uuid                     | NOT NULL
#  bucket_id    | text                     | NOT NULL
#  ip_version   | smallint                 | NOT NULL
#  cidrs        | cidr[]                   | NOT NULL DEFAULT '{}'::cidr[]
#  refreshed_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  provider_ip_range_pkey                                 | PRIMARY KEY btree (id)
#  provider_ip_range_location_id_bucket_id_ip_version_key | UNIQUE btree (location_id, bucket_id, ip_version)
#  provider_ip_range_refreshed_at_index                   | btree (refreshed_at)
# Check constraints:
#  ip_version_v4_or_v6 | (ip_version = ANY (ARRAY[4, 6]))
# Foreign key constraints:
#  provider_ip_range_location_id_fkey | (location_id) REFERENCES location(id) ON DELETE CASCADE
