# frozen_string_literal: true

require_relative "../model"

class SubjectTag < Sequel::Model
  include ResourceMethods

  def add_subject(subject_id)
    DB[:applied_subject_tag].insert(tag_id: id, subject_id:)
  end
end

# Table: subject_tag
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid | NOT NULL
#  name       | text | NOT NULL
# Indexes:
#  subject_tag_pkey                  | PRIMARY KEY btree (id)
#  subject_tag_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  subject_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  applied_subject_tag | applied_subject_tag_tag_id_fkey | (tag_id) REFERENCES subject_tag(id)
