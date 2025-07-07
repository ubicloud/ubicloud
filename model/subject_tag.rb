# frozen_string_literal: true

require_relative "../model"

class SubjectTag < Sequel::Model
  plugin ResourceMethods
  include AccessControlModelTag

  module Cleanup
    def before_destroy
      AccessControlEntry.where(subject_id: id).destroy
      DB[:applied_subject_tag].where(subject_id: id).delete
      super
    end
  end

  def self.subject_id_map_for_project_and_accounts(project_id, account_ids)
    DB[:applied_subject_tag]
      .join(:subject_tag, id: :tag_id)
      .where(project_id:, subject_id: account_ids)
      .order(:subject_id, :name)
      .select_hash_groups(:subject_id, :name)
  end

  def self.options_for_project(project)
    {
      "Tag" => project.subject_tags.reject { it.name == "Admin" },
      "Account" => project.accounts
    }
  end

  def self.valid_member?(project_id, subject)
    case subject
    when SubjectTag
      subject.project_id == project_id
    when Account
      !DB[:access_tag].where(project_id:, hyper_tag_id: subject.id).empty?
    when ApiKey
      subject.owner_table == "accounts" && subject.project_id == project_id
    end
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
