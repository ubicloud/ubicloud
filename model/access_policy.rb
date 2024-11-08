# frozen_string_literal: true

require_relative "../model"

class AccessPolicy < Sequel::Model
  many_to_one :project

  include ResourceMethods
end

# We need to unrestrict primary key so project.add_access_policy works
# in model/account.rb.
AccessPolicy.unrestrict_primary_key

# Table: access_policy
# Columns:
#  id         | uuid                     | PRIMARY KEY
#  project_id | uuid                     | NOT NULL
#  name       | text                     | NOT NULL
#  body       | jsonb                    | NOT NULL
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
#  managed    | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  access_policy_pkey                  | PRIMARY KEY btree (id)
#  access_policy_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  access_policy_project_id_fkey | (project_id) REFERENCES project(id)
