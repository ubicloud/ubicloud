#  frozen_string_literal: true

require_relative "../model"

class ProjectInvitation < Sequel::Model
  unrestrict_primary_key

  many_to_one :project, read_only: true
  many_to_one :inviter, class: :Account, read_only: true
end

# Table: project_invitation
# Primary Key: (project_id, email)
# Columns:
#  project_id | uuid                        |
#  email      | citext                      |
#  inviter_id | uuid                        | NOT NULL
#  expires_at | timestamp without time zone | NOT NULL
#  policy     | text                        |
# Indexes:
#  project_invitation_pkey           | PRIMARY KEY btree (project_id, email)
#  project_invitation_inviter_id_idx | btree (inviter_id)
# Foreign key constraints:
#  project_invitation_inviter_id_fkey | (inviter_id) REFERENCES accounts(id)
#  project_invitation_project_id_fkey | (project_id) REFERENCES project(id)
