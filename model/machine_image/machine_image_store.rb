# frozen_string_literal: true

require_relative "../../model"

class MachineImageStore < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:access_key, :secret_key]
end

# Table: machine_image_store
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id  | uuid                     | NOT NULL
#  location_id | uuid                     | NOT NULL
#  provider    | text                     | NOT NULL
#  region      | text                     | NOT NULL
#  endpoint    | text                     | NOT NULL
#  bucket      | text                     | NOT NULL
#  access_key  | text                     | NOT NULL
#  secret_key  | text                     | NOT NULL
# Indexes:
#  machine_image_store_pkey                       | PRIMARY KEY btree (id)
#  machine_image_store_project_id_location_id_key | UNIQUE btree (project_id, location_id)
# Foreign key constraints:
#  machine_image_store_location_id_fkey | (location_id) REFERENCES location(id)
#  machine_image_store_project_id_fkey  | (project_id) REFERENCES project(id)
# Referenced By:
#  machine_image_version_metal | machine_image_version_metal_store_id_fkey | (store_id) REFERENCES machine_image_store(id)
