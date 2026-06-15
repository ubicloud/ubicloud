# frozen_string_literal: true

require_relative "../../model"

class AppResource < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :private_subnet, read_only: true
  many_to_one :secret_store, read_only: true
  one_to_many :servers, class: :AppServer, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: app_resource
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(344)
#  project_id        | uuid                     | NOT NULL
#  location_id       | uuid                     | NOT NULL
#  name              | text                     | NOT NULL
#  repo_url          | text                     | NOT NULL
#  branch            | text                     | NOT NULL
#  target_vm_size    | text                     | NOT NULL
#  private_subnet_id | uuid                     |
#  secret_store_id   | uuid                     |
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  app_resource_pkey                              | PRIMARY KEY btree (id)
#  app_resource_project_id_location_id_name_index | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  app_resource_location_id_fkey       | (location_id) REFERENCES location(id)
#  app_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  app_resource_project_id_fkey        | (project_id) REFERENCES project(id)
#  app_resource_secret_store_id_fkey   | (secret_store_id) REFERENCES secret_store(id)
# Referenced By:
#  app_server | app_server_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
