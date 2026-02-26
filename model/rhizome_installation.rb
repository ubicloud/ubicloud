# frozen_string_literal: true

require_relative "../model"

class RhizomeInstallation < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: rhizome_installation
# Columns:
#  id           | uuid                     | PRIMARY KEY
#  folder       | text                     | NOT NULL
#  commit       | text                     | NOT NULL
#  digest       | text                     | NOT NULL
#  installed_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  rhizome_installation_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  rhizome_installation_id_fkey | (id) REFERENCES sshable(id) ON DELETE CASCADE
