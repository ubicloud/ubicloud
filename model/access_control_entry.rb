# frozen_string_literal: true

require_relative "../model"

class AccessControlEntry < Sequel::Model
  many_to_one :project

  include ResourceMethods

  # use __id__ if you want the internal object id
  def_column_alias :object_id, :object_id

  %I[subject action object].each do |type|
    method = :"#{type}_id"
    define_method(:"#{type}_ubid") do
      if (value = send(method))
        UBID.from_uuidish(value).to_s
      end
    end
  end

  def from_ubids(subject, action, object)
    self.subject_id, self.action_id, self.object_id = [subject, action, object].map! do
      UBID.to_uuid(_1) if _1
    end
    self
  end

  def validate
    if project_id
      {subject_id:, action_id:, object_id:}.each do |field, value|
        next unless value
        ubid = UBID.from_uuidish(value).to_s

        valid = case field
        when :subject_id
          SubjectTag.valid_member?(project_id, ubid.start_with?("et") ? ApiKey[value] : UBID.decode(ubid))
        when :action_id
          ActionTag.valid_member?(project_id, UBID.decode(ubid))
        else
          ObjectTag.valid_member?(project_id, UBID.decode(ubid))
        end

        unless valid
          errors.add(field, "is not related to this project")
        end
      end
    end

    super
  end
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
