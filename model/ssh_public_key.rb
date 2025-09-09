# frozen_string_literal: true

require_relative "../model"

class SshPublicKey < Sequel::Model
  plugin ResourceMethods
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
