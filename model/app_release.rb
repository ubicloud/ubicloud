# frozen_string_literal: true

require_relative "../model"

class AppRelease < Sequel::Model
  many_to_one :project, read_only: true
  one_to_many :app_release_snapshots, read_only: true

  plugin ResourceMethods
end

# Table: app_release
# Columns:
#  id             | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(344)
#  group_name     | text                     | NOT NULL
#  project_id     | uuid                     | NOT NULL
#  release_number | integer                  | NOT NULL
#  process_name   | text                     |
#  action         | text                     | NOT NULL
#  description    | text                     |
#  created_at     | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  app_release_pkey                                     | PRIMARY KEY btree (id)
#  app_release_project_id_group_name_release_number_key | UNIQUE btree (project_id, group_name, release_number)
#  app_release_project_id_index                         | btree (project_id)
# Foreign key constraints:
#  app_release_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  app_release_snapshot | app_release_snapshot_app_release_id_fkey | (app_release_id) REFERENCES app_release(id)
