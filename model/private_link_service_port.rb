# frozen_string_literal: true

require_relative "../model"

# Reached only through its service, so no ubid.
class PrivateLinkServicePort < Sequel::Model
  many_to_one :private_link_service
  one_to_one :private_link_service_port_aws_resource, key: :id, read_only: true

  plugin :association_dependencies, private_link_service_port_aws_resource: :destroy
end

# Table: private_link_service_port
# Columns:
#  id                      | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  created_at              | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  private_link_service_id | uuid                     | NOT NULL
#  port                    | integer                  | NOT NULL
#  target_port             | integer                  | NOT NULL
# Indexes:
#  private_link_service_port_pkey                             | PRIMARY KEY btree (id)
#  private_link_service_port_private_link_service_id_port_key | UNIQUE btree (private_link_service_id, port)
# Check constraints:
#  private_link_service_port_range | (port >= 1 AND port <= 65535 AND target_port >= 1 AND target_port <= 65535)
# Foreign key constraints:
#  private_link_service_port_private_link_service_id_fkey | (private_link_service_id) REFERENCES private_link_service(id) ON DELETE CASCADE
# Referenced By:
#  private_link_service_port_aws_resource | private_link_service_port_aws_resource_id_fkey | (id) REFERENCES private_link_service_port(id) ON DELETE CASCADE
