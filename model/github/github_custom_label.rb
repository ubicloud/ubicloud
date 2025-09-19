#  frozen_string_literal: true

require_relative "../../model"

class GithubCustomLabel < Sequel::Model
  plugin ResourceMethods

  def concurrency_limit_available?
    concurrent_runner_count_limit.nil? || allocated_runner_count < concurrent_runner_count_limit
  end
end

# Table: github_custom_label
# Columns:
#  id                            | uuid    | PRIMARY KEY DEFAULT gen_random_uuid()
#  installation_id               | uuid    | NOT NULL
#  label                         | text    | NOT NULL
#  alias_for                     | text    | NOT NULL
#  concurrent_runner_count_limit | integer |
#  allocated_runner_count        | integer | NOT NULL DEFAULT 0
# Indexes:
#  github_custom_label_pkey                      | PRIMARY KEY btree (id)
#  github_custom_label_installation_id_label_key | UNIQUE btree (installation_id, label)
# Check constraints:
#  allocated_runner_count_limit | (allocated_runner_count <= concurrent_runner_count_limit)
# Foreign key constraints:
#  github_custom_label_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
