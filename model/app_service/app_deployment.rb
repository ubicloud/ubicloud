# frozen_string_literal: true

require_relative "../../model"

class AppDeployment < Sequel::Model
  many_to_one :app_resource

  plugin ResourceMethods
end

# Table: app_deployment
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(350)
#  app_resource_id | uuid                     | NOT NULL
#  version         | integer                  | NOT NULL
#  commit_sha      | text                     |
#  status          | text                     | NOT NULL DEFAULT 'pending'::text
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  app_deployment_pkey                          | PRIMARY KEY btree (id)
#  app_deployment_app_resource_id_version_index | UNIQUE btree (app_resource_id, version)
# Foreign key constraints:
#  app_deployment_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
# Referenced By:
#  app_resource | app_resource_current_deployment_id_fkey | (current_deployment_id) REFERENCES app_deployment(id)
#  app_server   | app_server_current_deployment_id_fkey   | (current_deployment_id) REFERENCES app_deployment(id)
