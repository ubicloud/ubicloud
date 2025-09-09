# frozen_string_literal: true

require_relative "../model"

class SshPublicKey < Sequel::Model
  plugin ResourceMethods
  include Validation::PublicKeyValidation

  dataset_module do
    order :by_name, :name
  end

  def path
    "/ssh-public-key/#{ubid}"
  end

  def validate_ssh_public_key?
    true
  end

  def validate
    super
    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers, and hyphens and have max length 63.", allow_nil: true)
  end
end

# Table: ssh_public_key
# Columns:
#  id         | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(819)
#  project_id | uuid | NOT NULL
#  name       | text | NOT NULL
#  public_key | text | NOT NULL
# Indexes:
#  ssh_public_key_pkey                | PRIMARY KEY btree (id)
#  ssh_public_key_project_id_name_key | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  ssh_public_key_project_id_fkey | (project_id) REFERENCES project(id)
