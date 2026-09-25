# frozen_string_literal: true

require_relative "../../model"

class GithubCompletedWorkflowRun < Sequel::Model
  plugin DailyPartitionMethods, partition_type: :date
end

# Table: github_completed_workflow_run
# Primary Key: (repository_id, run_id, run_attempt, create_date)
# Columns:
#  repository_id             | uuid                     |
#  run_id                    | bigint                   |
#  run_attempt               | smallint                 |
#  create_date               | date                     |
#  installation_id           | uuid                     | NOT NULL
#  created_at                | timestamp with time zone | NOT NULL
#  run_started_at            | timestamp with time zone |
#  completed_at              | timestamp with time zone |
#  head_branch               | text                     |
#  head_repository_full_name | text                     |
#  event                     | text                     | NOT NULL
#  status                    | text                     | NOT NULL
#  conclusion                | text                     |
#  display_title             | text                     | NOT NULL
#  commit_hash               | text                     |
#  commit_message            | text                     |
#  actor_login               | text                     | NOT NULL
#  duration                  | integer                  |
# Indexes:
#  github_completed_workflow_run_pkey                             | PRIMARY KEY btree (repository_id, create_date, run_id, run_attempt)
#  github_completed_workflow_run_installation_id_completed_at_idx | btree (installation_id, completed_at DESC)
#  github_completed_workflow_run_repository_id_completed_at_idx   | btree (repository_id, completed_at DESC)
