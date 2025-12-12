# frozen_string_literal: true

require_relative "../model"

class ProjectDiscountCode < Sequel::Model
  many_to_one :project

  plugin ResourceMethods
end

# Table: project_discount_code
# Columns:
#  id               | uuid                     | PRIMARY KEY
#  created_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id       | uuid                     | NOT NULL
#  discount_code_id | uuid                     | NOT NULL
# Indexes:
#  project_discount_code_pkey                            | PRIMARY KEY btree (id)
#  project_discount_code_project_id_discount_code_id_key | UNIQUE btree (project_id, discount_code_id)
# Foreign key constraints:
#  project_discount_code_discount_code_id_fkey | (discount_code_id) REFERENCES discount_code(id)
#  project_discount_code_project_id_fkey       | (project_id) REFERENCES project(id)
