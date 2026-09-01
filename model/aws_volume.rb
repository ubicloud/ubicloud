# frozen_string_literal: true

require_relative "../model"

class AwsVolume < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_NETWORK_VOLUME

  many_to_one :network_volume, key: :id
end

# Table: aws_volume
# Columns:
#  id                           | uuid    | PRIMARY KEY
#  volume_type                  | text    | NOT NULL
#  provisioned_iops             | integer |
#  provisioned_throughput_mibps | integer |
# Indexes:
#  aws_volume_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  aws_volume_iops_positive       | (provisioned_iops IS NULL OR provisioned_iops > 0)
#  aws_volume_throughput_positive | (provisioned_throughput_mibps IS NULL OR provisioned_throughput_mibps > 0)
#  aws_volume_type_check          | (volume_type = ANY (ARRAY['gp3'::text, 'io2'::text]))
# Foreign key constraints:
#  aws_volume_id_fkey | (id) REFERENCES network_volume(id) ON DELETE CASCADE
