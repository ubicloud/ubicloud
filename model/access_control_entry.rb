# frozen_string_literal: true

require_relative "../model"

class AccessControlEntry < Sequel::Model
  include ResourceMethods
end

# Table: access_control_entry
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid | NOT NULL
#  subject_id | uuid | NOT NULL
#  action_id  | uuid |
#  object_id  | uuid |
# Indexes:
#  access_control_entry_pkey                                       | PRIMARY KEY btree (id)
#  access_control_entry_project_id_subject_id_action_id_object_id_ | btree (project_id, subject_id, action_id, object_id)
# Foreign key constraints:
#  access_control_entry_project_id_fkey | (project_id) REFERENCES project(id)
