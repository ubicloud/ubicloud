# frozen_string_literal: true

require_relative "../model"

class MachineImage < Sequel::Model
  many_to_one :project
  many_to_one :location

  plugin ResourceMethods
end

# Table: machine_image
# Columns:
#  id            | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(641)
#  name          | text                     | NOT NULL
#  bucket_prefix | text                     | NOT NULL
#  created_at    | timestamp with time zone | NOT NULL DEFAULT now()
#  ready         | boolean                  | NOT NULL DEFAULT false
#  project_id    | uuid                     | NOT NULL
#  location_id   | uuid                     | NOT NULL
# Indexes:
#  machine_image_pkey              | PRIMARY KEY btree (id)
#  machine_image_location_id_index | btree (location_id)
#  machine_image_project_id_index  | btree (project_id)
# Foreign key constraints:
#  machine_image_location_id_fkey | (location_id) REFERENCES location(id)
#  machine_image_project_id_fkey  | (project_id) REFERENCES project(id)
