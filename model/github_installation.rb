# frozen_string_literal: true

require_relative "../model"

class GithubInstallation < Sequel::Model
  many_to_one :project
  one_to_many :runners, key: :installation_id, class: :GithubRunner
  one_to_many :repositories, key: :installation_id, class: :GithubRepository

  include ResourceMethods

  def installation_url
    if type == "Organization"
      return "https://github.com/organizations/#{name}/settings/installations/#{installation_id}"
    end
    "https://github.com/settings/installations/#{installation_id}"
  end

  def total_active_runner_cores
    runner_labels = runners_dataset.left_join(:strand, id: :id).exclude(Sequel[:strand][:label] => "start").exclude(Sequel[:strand][:label] => "wait_concurrency_limit").select_map(Sequel[:github_runner][:label])
    vm_size_data_set = runner_labels.map { |label| Github.runner_labels[label]["vm_size"] }
    vm_size_data_set.sum { |size| Validation.validate_vm_size(size).vcpu }
  end
end
