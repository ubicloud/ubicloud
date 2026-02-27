# frozen_string_literal: true

require_relative "../model"

class MachineImage < Sequel::Model
  many_to_one :project
  many_to_one :location
  one_to_many :versions, class: :MachineImageVersion, order: Sequel.desc(:created_at)

  plugin ResourceMethods
  include ObjectTag::Cleanup

  dataset_module Pagination

  dataset_module do
    def for_project(project_id)
      where(project_id:)
    end
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/machine-image/#{ubid}"
  end

  def active_version
    if associations.key?(:versions)
      # Use eager-loaded versions to avoid N+1 queries
      versions.select(&:activated_at).max_by(&:activated_at)
    else
      MachineImageVersion.where(machine_image_id: id)
        .exclude(activated_at: nil)
        .order(Sequel.desc(:activated_at))
        .first
    end
  end

  def deleting?
    deleting
  end

  def before_destroy
    versions.each(&:destroy)
    super
  end
end

# Table: machine_image
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  name        | text                     | NOT NULL
#  description | text                     | NOT NULL DEFAULT ''::text
#  project_id  | uuid                     | NOT NULL
#  location_id | uuid                     | NOT NULL
#  arch        | text                     | NOT NULL DEFAULT 'x64'::text
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  machine_image_pkey                            | PRIMARY KEY btree (id)
#  machine_image_project_id_location_id_name_key | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  machine_image_location_id_fkey | (location_id) REFERENCES location(id)
#  machine_image_project_id_fkey  | (project_id) REFERENCES project(id)
# Referenced By:
#  machine_image_version | machine_image_version_machine_image_id_fkey | (machine_image_id) REFERENCES machine_image(id)
