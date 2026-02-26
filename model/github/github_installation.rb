# frozen_string_literal: true

require_relative "../../model"

class GithubInstallation < Sequel::Model
  many_to_one :project
  one_to_many :runners, key: :installation_id, class: :GithubRunner, remover: nil, clearer: nil, is_used: true
  one_to_many :repositories, key: :installation_id, class: :GithubRepository, read_only: true, is_used: true
  one_to_many :custom_labels, class: :GithubCustomLabel, key: :installation_id, read_only: true
  many_to_many :cache_entries, join_table: :github_repository, right_key: :id, right_primary_key: :repository_id, left_key: :installation_id, class: :GithubCacheEntry, read_only: true

  plugin ResourceMethods
  dataset_module Pagination

  def self.with_github_installation_id(installation_id)
    first(installation_id:)
  end

  def total_active_runner_vcpus
    runners_dataset.total_active_runner_vcpus
  end

  def free_runner_upgrade?(at = Time.now)
    free_runner_upgrade_expires_at > at
  end

  def free_runner_upgrade_expires_at
    dates = [created_at + 7 * 24 * 60 * 60]
    if (upgrade_until = project.get_ff_free_runner_upgrade_until)
      dates.push(Time.parse(upgrade_until))
    end
    dates.max
  end

  def premium_runner_enabled?
    !!allocator_preferences["family_filter"]&.include?("premium")
  end

  def client(**)
    Github.installation_client(installation_id, **)
  end

  def cache_storage_gib
    [project.effective_quota_value("GithubRunnerCacheStorage"), premium_runner_enabled? ? 100 : 0].max
  end
end

# Table: github_installation
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  installation_id       | bigint                   | NOT NULL
#  name                  | text                     | NOT NULL
#  type                  | text                     | NOT NULL
#  project_id            | uuid                     |
#  cache_enabled         | boolean                  | NOT NULL DEFAULT true
#  use_docker_mirror     | boolean                  | NOT NULL DEFAULT false
#  allocator_preferences | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  created_at            | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  cache_scope_protected | boolean                  | NOT NULL DEFAULT true
# Indexes:
#  github_installation_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  github_installation_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  github_custom_label | github_custom_label_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_repository   | github_repository_installation_id_fkey   | (installation_id) REFERENCES github_installation(id)
#  github_runner       | github_runner_installation_id_fkey       | (installation_id) REFERENCES github_installation(id)
