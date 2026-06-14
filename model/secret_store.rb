# frozen_string_literal: true

require_relative "../model"

class SecretStore < Sequel::Model
  many_to_one :project
  one_to_many :secrets, order: :key

  plugin :association_dependencies, secrets: :destroy
  plugin ResourceMethods
  include ObjectTag::Cleanup

  def path
    "/secret-store/#{ubid}"
  end

  def validate
    super
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers, and hyphens and have max length 63.", allow_nil: true)
  end
end

# Table: secret_store
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(825)
#  project_id  | uuid                     | NOT NULL
#  name        | text                     | NOT NULL
#  description | text                     |
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  secret_store_pkey                  | PRIMARY KEY btree (id)
#  secret_store_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  secret_store_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  secret | secret_secret_store_id_fkey | (secret_store_id) REFERENCES secret_store(id)
