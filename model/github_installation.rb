# frozen_string_literal: true

require_relative "../model"

class GithubInstallation < Sequel::Model
  many_to_one :project
  one_to_many :runners, key: :installation_id, class: :GithubRunner
  one_to_many :repositories, key: :installation_id, class: :GithubRepository

  include ResourceMethods

  def total_active_runner_cores
    runner_labels = runners_dataset.left_join(:strand, id: :id).exclude(Sequel[:strand][:label] => "start").exclude(Sequel[:strand][:label] => "wait_concurrency_limit").select_map(Sequel[:github_runner][:label])
    label_record_data_set = runner_labels.map { |label| Github.runner_labels[label] }
    label_record_data_set.sum do |label_record|
      vcpu = Validation.validate_vm_size(label_record["vm_size"]).vcpu
      if label_record["arch"] == "arm64"
        vcpu
      else
        vcpu / 2
      end
    end
  end
end

# Table: github_installation
# Columns:
#  id              | uuid   | PRIMARY KEY
#  installation_id | bigint | NOT NULL
#  name            | text   | NOT NULL
#  type            | text   | NOT NULL
#  project_id      | uuid   |
# Indexes:
#  github_installation_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  github_installation_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  github_repository | github_repository_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner     | github_runner_installation_id_fkey     | (installation_id) REFERENCES github_installation(id)
