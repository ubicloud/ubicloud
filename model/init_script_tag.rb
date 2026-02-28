# frozen_string_literal: true

require_relative "../model"

class InitScriptTag < Sequel::Model
  many_to_one :project, read_only: true

  plugin ResourceMethods, encrypted_columns: :init_script
  include ObjectTag::Cleanup

  dataset_module Pagination

  def ref
    "#{name}@#{version}"
  end
end

# Table: init_script_tag
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(58)
#  project_id  | uuid                     | NOT NULL
#  name        | text                     | NOT NULL
#  version     | integer                  | NOT NULL
#  init_script | text                     | NOT NULL
#  description | text                     |
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  init_script_tag_pkey                        | PRIMARY KEY btree (id)
#  init_script_tag_project_id_name_version_key | UNIQUE btree (project_id, name, version)
#  init_script_tag_project_id_index            | btree (project_id)
# Foreign key constraints:
#  init_script_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  app_member_init           | app_member_init_init_script_tag_id_fkey           | (init_script_tag_id) REFERENCES init_script_tag(id)
#  app_process_init          | app_process_init_init_script_tag_id_fkey          | (init_script_tag_id) REFERENCES init_script_tag(id)
#  app_release_snapshot_init | app_release_snapshot_init_init_script_tag_id_fkey | (init_script_tag_id) REFERENCES init_script_tag(id)
