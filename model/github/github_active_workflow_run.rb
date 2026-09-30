# frozen_string_literal: true

require_relative "../../model"

class GithubActiveWorkflowRun < Sequel::Model
  many_to_one :installation, class: :GithubInstallation, read_only: true
  many_to_one :repository, class: :GithubRepository, read_only: true
  one_to_many :active_runners, class: :GithubRunner, key: [:repository_id, :run_id, :run_attempt], primary_key: [:repository_id, :run_id, :run_attempt], order: :job_id, read_only: true
  one_to_many :completed_workflow_jobs, class: :GithubCompletedWorkflowJob, key: [:workflow_run_create_date, :repository_id, :run_id, :run_attempt], primary_key: [:create_date, :repository_id, :run_id, :run_attempt], order: :job_id, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy

  def completed?
    false
  end

  def duration
    if run_started_at && completed_at
      (completed_at - run_started_at).ceil
    end
  end
end

# Table: github_active_workflow_run
# Columns:
#  id                        | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(540)
#  installation_id           | uuid                     | NOT NULL
#  repository_id             | uuid                     | NOT NULL
#  create_date               | date                     | NOT NULL
#  created_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  run_started_at            | timestamp with time zone |
#  completed_at              | timestamp with time zone |
#  run_id                    | bigint                   | NOT NULL
#  run_attempt               | smallint                 | NOT NULL
#  repository_name           | text                     | NOT NULL
#  head_branch               | text                     |
#  head_repository_full_name | text                     |
#  event                     | text                     | NOT NULL
#  status                    | text                     | NOT NULL
#  conclusion                | text                     |
#  display_title             | text                     | NOT NULL
#  commit_hash               | text                     |
#  commit_message            | text                     |
#  actor_login               | text                     | NOT NULL
#  cache_scope               | text                     | NOT NULL
# Indexes:
#  github_active_workflow_run_pkey                                 | PRIMARY KEY btree (id)
#  github_active_workflow_run_repository_id_run_id_run_attempt_ind | UNIQUE btree (repository_id, run_id, run_attempt)
#  github_active_workflow_run_installation_id_created_at_idx       | btree (installation_id, created_at DESC)
#  github_active_workflow_run_installation_id_repository_name_run_ | btree (installation_id, repository_name, run_id, run_attempt)
#  github_active_workflow_run_repository_id_created_at_idx         | btree (repository_id, created_at DESC)
# Foreign key constraints:
#  github_active_workflow_run_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_active_workflow_run_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
