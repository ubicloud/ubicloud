# frozen_string_literal: true

require_relative "../../model"

class AppProcess < Sequel::Model
  many_to_one :app_resource
  one_to_many :servers, class: :AppServer, read_only: true

  plugin ResourceMethods

  def web?
    process_type == "web"
  end
end

# Table: app_process
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(343)
#  app_resource_id | uuid                     | NOT NULL
#  process_type    | text                     | NOT NULL
#  replica_count   | integer                  | NOT NULL DEFAULT 1
#  vm_size         | text                     | NOT NULL
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  app_process_pkey                               | PRIMARY KEY btree (id)
#  app_process_app_resource_id_process_type_index | UNIQUE btree (app_resource_id, process_type)
# Foreign key constraints:
#  app_process_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
# Referenced By:
#  app_server | app_server_app_process_id_fkey | (app_process_id) REFERENCES app_process(id)
