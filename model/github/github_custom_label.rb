#  frozen_string_literal: true

require_relative "../../model"

class GithubCustomLabel < Sequel::Model
  plugin ResourceMethods
end

# Table: github_custom_label
# Columns:
#  id                            | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(524)
#  installation_id               | uuid    | NOT NULL
#  name                          | text    | NOT NULL
#  alias_for                     | text    | NOT NULL
#  concurrent_runner_count_limit | integer |
#  allocated_runner_count        | integer | NOT NULL DEFAULT 0
# Indexes:
#  github_custom_label_pkey                     | PRIMARY KEY btree (id)
#  github_custom_label_installation_id_name_key | UNIQUE btree (installation_id, name)
# Check constraints:
#  allocated_runner_count_limit           | (allocated_runner_count <= concurrent_runner_count_limit)
#  concurrent_runner_count_limit_positive | (concurrent_runner_count_limit > 0)
# Foreign key constraints:
#  github_custom_label_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
