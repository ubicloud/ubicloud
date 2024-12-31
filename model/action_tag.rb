# frozen_string_literal: true

require_relative "../model"

class ActionTag < Sequel::Model
  include ResourceMethods
  include AccessControlModelTag

  def self.valid_member?(project_id, action)
    case action
    when ActionTag
      action.project_id == project_id || !action.project_id
    when ActionType
      true
    end
  end
end

# Table: action_tag
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid |
#  name       | text | NOT NULL
# Indexes:
#  action_tag_pkey                  | PRIMARY KEY btree (id)
#  action_tag_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  action_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  applied_action_tag | applied_action_tag_tag_id_fkey | (tag_id) REFERENCES action_tag(id)
