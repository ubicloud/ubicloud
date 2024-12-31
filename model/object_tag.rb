# frozen_string_literal: true

require_relative "../model"

class ObjectTag < Sequel::Model
  include ResourceMethods
  include AccessControlModelTag

  def self.valid_member?(project_id, object)
    case object
    when ObjectTag, SubjectTag, ActionTag, InferenceEndpoint
      object.project_id == project_id
    when Vm, PrivateSubnet, PostgresResource, Firewall, LoadBalancer
      !AccessTag.where(project_id:, hyper_tag_id: object.id).empty?
    when Project
      object.id == project_id
    when ApiKey
      object.owner_table == "project" && object.owner_id == project_id
    end
  end
end

# Table: object_tag
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid | NOT NULL
#  name       | text | NOT NULL
# Indexes:
#  object_tag_pkey                  | PRIMARY KEY btree (id)
#  object_tag_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  object_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  applied_object_tag | applied_object_tag_tag_id_fkey | (tag_id) REFERENCES object_tag(id)
