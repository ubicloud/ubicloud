# frozen_string_literal: true

require_relative "../../model"

class MachineImage < Sequel::Model
  many_to_one :project
  many_to_one :location
  many_to_one :latest_version, class: :MachineImageVersion
  one_to_many :versions, class: :MachineImageVersion, order: Sequel.desc(:created_at)

  plugin ResourceMethods
end

# Table: machine_image
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  name              | text                     | NOT NULL
#  arch              | text                     | NOT NULL
#  project_id        | uuid                     | NOT NULL
#  location_id       | uuid                     | NOT NULL
#  latest_version_id | uuid                     |
# Indexes:
#  machine_image_pkey                            | PRIMARY KEY btree (id)
#  machine_image_project_id_location_id_name_key | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  machine_image_latest_version_id_fkey | (latest_version_id) REFERENCES machine_image_version(id)
#  machine_image_location_id_fkey       | (location_id) REFERENCES location(id)
#  machine_image_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  machine_image_version | machine_image_version_machine_image_id_fkey | (machine_image_id) REFERENCES machine_image(id)
