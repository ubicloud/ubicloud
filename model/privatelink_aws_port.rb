# frozen_string_literal: true

require_relative "../model"

class PrivatelinkAwsPort < Sequel::Model
  many_to_one :privatelink_aws_resource
  one_to_many :vm_ports, class: :PrivatelinkAwsVmPort, key: :privatelink_aws_port_id

  plugin ResourceMethods
end

# Table: privatelink_aws_port
# Columns:
#  id                            | uuid                     | PRIMARY KEY
#  created_at                    | timestamp with time zone | NOT NULL DEFAULT now()
#  privatelink_aws_resource_id   | uuid                     | NOT NULL
#  src_port                      | integer                  | NOT NULL
#  dst_port                      | integer                  | NOT NULL
#  target_group_arn              | text                     |
#  listener_arn                  | text                     |
# Indexes:
#  privatelink_aws_port_pkey                                    | PRIMARY KEY btree (id)
#  privatelink_aws_port_privatelink_aws_resource_id_src_port_index | UNIQUE btree (privatelink_aws_resource_id, src_port)
# Check constraints:
#  dst_port_range | (dst_port >= 1 AND dst_port <= 65535)
#  src_port_range | (src_port >= 1 AND src_port <= 65535)
# Foreign key constraints:
#  privatelink_aws_port_privatelink_aws_resource_id_fkey | (privatelink_aws_resource_id) REFERENCES privatelink_aws_resource(id) ON DELETE CASCADE
