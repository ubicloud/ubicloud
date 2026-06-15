# frozen_string_literal: true

require_relative "../../model"

class AppServer < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :app_resource
  many_to_one :vm, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: app_server
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(342)
#  app_resource_id | uuid                     | NOT NULL
#  vm_id           | uuid                     |
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  app_server_pkey                  | PRIMARY KEY btree (id)
#  app_server_app_resource_id_index | btree (app_resource_id)
# Foreign key constraints:
#  app_server_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
#  app_server_vm_id_fkey           | (vm_id) REFERENCES vm(id)
