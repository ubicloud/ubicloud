# frozen_string_literal: true

require_relative "../model"

class ResourceCredit < Sequel::Model
  many_to_one :project, read_only: true

  plugin ResourceMethods
  include ResourceMatchable
end

# Table: resource_credit
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(777)
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id      | uuid                     | NOT NULL
#  name            | text                     | NOT NULL
#  resource_id     | uuid                     |
#  resource_type   | text                     |
#  resource_family | text                     |
#  location        | text                     |
#  byoc            | boolean                  |
#  amount          | numeric                  | NOT NULL
#  active_from     | timestamp with time zone | NOT NULL
#  active_to       | timestamp with time zone |
# Indexes:
#  resource_credit_pkey             | PRIMARY KEY btree (id)
#  resource_credit_project_id_index | btree (project_id)
# Check constraints:
#  resource_credit_active_range              | (active_from < active_to OR active_to IS NULL)
#  resource_credit_amount_range              | (amount >= 0::numeric)
#  resource_credit_month_aligned             | (date_trunc('month'::text, active_from, 'UTC'::text) = active_from AND (active_to IS NULL OR date_trunc('month'::text, active_to, 'UTC'::text) = active_to))
#  resource_credit_resource_id_requires_type | (resource_id IS NULL OR resource_type IS NOT NULL)
# Foreign key constraints:
#  resource_credit_project_id_fkey | (project_id) REFERENCES project(id)
