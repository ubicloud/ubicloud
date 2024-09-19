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
