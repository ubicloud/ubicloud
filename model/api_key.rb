# frozen_string_literal: true

require_relative "../model"

class ApiKey < Sequel::Model
  include ResourceMethods
  include Authorization::HyperTagMethods
  include SubjectTag::Cleanup # personal access tokens
  include ObjectTag::Cleanup # inference tokens

  one_to_many :access_tags, key: :hyper_tag_id
  plugin :association_dependencies, access_tags: :destroy

  plugin :column_encryption do |enc|
    enc.column :key
  end

  def hyper_tag_name(project = nil)
    "api-key/#{ubid}"
  end

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def name
    ubid
  end

  def self.create_personal_access_token(account, project: nil)
    pat = create_with_id(owner_table: "accounts", owner_id: account.id, used_for: "api", project_id: project&.id)
    pat.associate_with_project(project) if project
    pat
  end

  def self.create_inference_api_key(project)
    token = ApiKey.create_with_id(owner_table: "project", owner_id: project.id, used_for: "inference_endpoint", project_id: project.id)
    token.associate_with_project(project)
    token
  end

  def self.create_with_id(owner_table:, owner_id:, used_for:, project_id:)
    unless %w[project inference_endpoint accounts].include?(owner_table.to_s)
      fail "Invalid owner_table: #{owner_table}"
    end

    key = SecureRandom.alphanumeric(32)
    super(owner_table:, owner_id:, key:, used_for:, project_id:)
  end

  def unrestricted_token_for_project?(project_id)
    !unrestricted_project_access_dataset(project_id).empty?
  end

  def restrict_token_for_project(project_id)
    unrestricted_project_access_dataset(project_id).delete
  end

  def unrestrict_token_for_project(project_id)
    AccessControlEntry.where(project_id:, subject_id: id).destroy
    DB[:applied_subject_tag]
      .insert_ignore
      .insert(subject_id: id, tag_id: SubjectTag.where(project_id:, name: "Admin").select(:id))
  end

  def rotate
    new_key = SecureRandom.alphanumeric(32)
    update(key: new_key, updated_at: Time.now)
  end

  private

  def unrestricted_project_access_dataset(project_id)
    DB[:applied_subject_tag]
      .where(subject_id: id, tag_id: SubjectTag.where(project_id:, name: "Admin").select(:id))
  end
end

# Table: api_key
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  owner_table | text                     | NOT NULL
#  owner_id    | uuid                     | NOT NULL
#  used_for    | text                     | NOT NULL
#  key         | text                     | NOT NULL
#  is_valid    | boolean                  | NOT NULL DEFAULT true
#  project_id  | uuid                     |
# Indexes:
#  api_key_pkey                       | PRIMARY KEY btree (id)
#  api_key_owner_table_owner_id_index | btree (owner_table, owner_id)
