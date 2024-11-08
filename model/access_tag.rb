# frozen_string_literal: true

require_relative "../model"

class AccessTag < Sequel::Model
  many_to_one :project
  one_to_many :applied_tags

  plugin :association_dependencies, applied_tags: :destroy

  include ResourceMethods
end

# Table: access_tag
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  project_id      | uuid                     | NOT NULL
#  hyper_tag_id    | uuid                     |
#  hyper_tag_table | text                     | NOT NULL
#  name            | text                     | NOT NULL
#  created_at      | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  access_tag_pkey                          | PRIMARY KEY btree (id)
#  access_tag_project_id_hyper_tag_id_index | UNIQUE btree (project_id, hyper_tag_id)
#  access_tag_project_id_name_index         | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  access_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  applied_tag | applied_tag_access_tag_id_fkey | (access_tag_id) REFERENCES access_tag(id)
