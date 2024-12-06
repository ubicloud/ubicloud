# frozen_string_literal: true

require_relative "../model"

class AccessControlEntry < Sequel::Model
  many_to_one :project

  include ResourceMethods

  # use __id__ if you want the internal object id
  def_column_alias :object_id, :object_id

  def validate
    if project_id
      {subject_id:, action_id:, object_id:}.each do |field, value|
        next unless value
        ubid = UBID.from_uuidish(value).to_s

        valid = case field
        when :subject_id
          case (subject = ubid.start_with?("et") ? ApiKey[value] : UBID.decode(ubid))
          when SubjectTag
            subject.project_id == project_id
          when Account
            !AccessTag.where(project_id: project_id, hyper_tag_id: value).empty?
          when ApiKey
            subject.owner_table == "accounts" &&
              !AccessTag.where(project_id: project_id, hyper_tag_id: subject.owner_id).empty?
          end
        when :action_id
          case (action = UBID.decode(ubid))
          when ActionTag
            action.project_id == project_id
          when ActionType
            true
          end
        else
          case (object = UBID.decode(ubid))
          when ObjectTag, SubjectTag, ActionTag
            object.project_id == project_id
          when Vm, PrivateSubnet, PostgresResource, Firewall, LoadBalancer
            !AccessTag.where(project_id: project_id, hyper_tag_id: value).empty?
          end
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
