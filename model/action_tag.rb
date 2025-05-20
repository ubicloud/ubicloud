# frozen_string_literal: true

require_relative "../model"

class ActionTag < Sequel::Model
  include ResourceMethods
  include AccessControlModelTag

  MEMBER_ID = "ffffffff-ff00-834a-87ff-ff828ea2dd80"

  dataset_module do
    where :global, project_id: nil
    order :by_name, :name

    def global_by_name
      global.by_name
    end
  end

  plugin :subset_static_cache
  cache_subset :global_by_name

  def self.options_for_project(project)
    {
      "Global Tag" => ActionTag.global_by_name.all,
      "Tag" => project.action_tags,
      "Action" => ActionType
    }
  end

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
