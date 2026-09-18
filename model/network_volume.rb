# frozen_string_literal: true

require_relative "../model"

# A provider-managed disk that can outlive its VM attachment.
class NetworkVolume < Sequel::Model
  plugin ResourceMethods
end

# Table: network_volume
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(699)
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location_id | uuid                     | NOT NULL
#  provider_id | text                     |
#  size_gib    | bigint                   | NOT NULL
# Indexes:
#  network_volume_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  network_volume_size_positive | (size_gib > 0)
# Foreign key constraints:
#  network_volume_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  aws_volume        | aws_volume_id_fkey                       | (id) REFERENCES network_volume(id) ON DELETE CASCADE
#  gcp_volume        | gcp_volume_id_fkey                       | (id) REFERENCES network_volume(id) ON DELETE CASCADE
#  vm_storage_volume | vm_storage_volume_network_volume_id_fkey | (network_volume_id) REFERENCES network_volume(id)
