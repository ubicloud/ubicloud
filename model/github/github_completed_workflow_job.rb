# frozen_string_literal: true

require_relative "../../model"

class GithubCompletedWorkflowJob < Sequel::Model
  plugin DailyPartitionMethods, partition_type: :date

  def completed?
    true
  end
end

# Table: github_completed_workflow_job
# Primary Key: (repository_id, job_id, workflow_run_create_date)
# Columns:
#  repository_id            | uuid                     |
#  job_id                   | bigint                   |
#  workflow_run_create_date | date                     |
#  installation_id          | uuid                     | NOT NULL
#  runner_id                | uuid                     | NOT NULL
#  runner_vm_id             | uuid                     | NOT NULL
#  created_at               | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  completed_at             | timestamp with time zone | NOT NULL
#  run_id                   | bigint                   | NOT NULL
#  run_attempt              | smallint                 | NOT NULL
#  head_branch              | text                     |
#  workflow_name            | text                     |
#  job_name                 | text                     | NOT NULL
#  job_created_at           | timestamp with time zone | NOT NULL
#  job_started_at           | timestamp with time zone | NOT NULL
#  job_completed_at         | timestamp with time zone |
#  ready_at                 | timestamp with time zone | NOT NULL
#  status                   | text                     | NOT NULL
#  conclusion               | text                     |
#  label                    | text                     | NOT NULL
#  actual_label             | text                     | NOT NULL
#  billed_vm_size           | text                     | NOT NULL
#  vm_family                | text                     | NOT NULL
#  duration                 | integer                  | NOT NULL
# Indexes:
#  github_completed_workflow_job_pkey                              | PRIMARY KEY btree (repository_id, workflow_run_create_date, job_id)
#  github_completed_workflow_job_installation_id_completed_at_idx  | btree (installation_id, completed_at DESC)
#  github_completed_workflow_job_repository_id_completed_at_idx    | btree (repository_id, completed_at DESC)
#  github_completed_workflow_job_repository_id_run_id_run_attempt_ | btree (repository_id, run_id, run_attempt, job_id)
