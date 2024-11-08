#  frozen_string_literal: true

require_relative "../model"

class ProjectInvitation < Sequel::Model
  many_to_one :project
end

ProjectInvitation.unrestrict_primary_key

# Table: project_invitation
# Primary Key: (project_id, email)
# Columns:
#  project_id | uuid                        |
#  email      | citext                      |
#  inviter_id | uuid                        | NOT NULL
#  expires_at | timestamp without time zone | NOT NULL
#  policy     | text                        |
# Indexes:
#  project_invitation_pkey | PRIMARY KEY btree (project_id, email)
