# frozen_string_literal: true

require_relative "../model"

class GcpVolume < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_NETWORK_VOLUME

  many_to_one :network_volume, key: :id
end

# Table: gcp_volume
# Columns:
#  id                           | uuid    | PRIMARY KEY
#  volume_type                  | text    | NOT NULL
#  provisioned_iops             | integer |
#  provisioned_throughput_mibps | integer |
# Indexes:
#  gcp_volume_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  gcp_volume_iops_positive       | (provisioned_iops IS NULL OR provisioned_iops > 0)
#  gcp_volume_throughput_positive | (provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0)
#  gcp_volume_type_check          | (volume_type = 'hyperdisk-balanced'::text)
# Foreign key constraints:
#  gcp_volume_id_fkey | (id) REFERENCES network_volume(id) ON DELETE CASCADE
