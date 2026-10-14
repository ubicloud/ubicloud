# frozen_string_literal: true

require_relative "../../model"

class GithubRunnerCapacity < Sequel::Model
  unrestrict_primary_key
end

# Table: github_runner_capacity
# Columns:
#  name               | text                     | PRIMARY KEY
#  total_cores        | integer                  | NOT NULL DEFAULT 0
#  total_hugepages_1g | integer                  | NOT NULL DEFAULT 0
#  used_cores         | integer                  | NOT NULL DEFAULT 0
#  used_hugepages_1g  | integer                  | NOT NULL DEFAULT 0
#  used_vcpus         | integer                  | NOT NULL DEFAULT 0
#  used_runners       | integer                  | NOT NULL DEFAULT 0
#  reconciled_at      | timestamp with time zone |
# Indexes:
#  github_runner_capacity_pkey | PRIMARY KEY btree (name)
