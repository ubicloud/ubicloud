# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  many_to_one :repository, key: :repository_id, class: :GithubRepository
  one_to_one :vm, key: :id, primary_key: :vm_id
  one_through_one :project, join_table: :github_installation, left_key: :id, left_primary_key: :installation_id, read_only: true

  plugin ResourceMethods, redacted_columns: :workflow_job
  plugin SemaphoreMethods, :destroy, :skip_deregistration
  include HealthMonitorMethods

  dataset_module do
    def total_active_runner_vcpus
      left_join(:strand, id: :id)
        .exclude(Sequel[:strand][:label] => ["start", "wait_concurrency_limit"])
        .select_map(Sequel[:github_runner][:label])
        .sum { Github.runner_labels[it]["vcpus"] }
    end
  end

  def label_data
    @label_data ||= Github.runner_labels[label]
  end

  def repository_url
    "http://github.com/#{repository_name}"
  end

  def run_url
    "#{repository_url}/actions/runs/#{workflow_job["run_id"]}"
  end

  def job_url
    "#{run_url}/job/#{workflow_job["id"]}"
  end

  def runner_url
    "#{repository_url}/settings/actions/runners/#{runner_id}" if runner_id
  end

  def log_duration(message, duration)
    values = {ubid:, label:, repository_name:, duration:, conclusion: workflow_job&.dig("conclusion")}
    if vm
      values.merge!(vm_ubid: vm.ubid, arch: vm.arch, cores: vm.cores, vcpus: vm.vcpus)
      if (ch_version = vm.strand&.stack&.dig(0, "ch_version"))
        values[:ch_version] = ch_version
      end
      if vm.vm_host
        values[:vm_host_ubid] = vm.vm_host.ubid
        values[:data_center] = vm.vm_host.data_center
      end
      values[:vm_pool_ubid] = VmPool[vm.pool_id].ubid if vm.pool_id
    end
    Clog.emit(message) { {message => values} }
  end

  def provision_spare_runner
    Prog::Vm::GithubRunner.assemble(installation, repository_name: repository_name, label: label).subject
  end

  def init_health_monitor_session
    {
      ssh_session: vm.sshable.start_fresh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      available_memory = session[:ssh_session].exec!("awk '/MemAvailable/ {print $2}' /proc/meminfo").chomp
      "up"
    rescue
      "down"
    end
    aggregate_readings(previous_pulse: previous_pulse, reading: reading, data: {available_memory: available_memory})
  end
end

# Table: github_runner
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  installation_id | uuid                     |
#  repository_name | text                     | NOT NULL
#  label           | text                     | NOT NULL
#  vm_id           | uuid                     |
#  runner_id       | bigint                   |
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  ready_at        | timestamp with time zone |
#  workflow_job    | jsonb                    |
#  repository_id   | uuid                     |
#  allocated_at    | timestamp with time zone |
#  billed_vm_size  | text                     |
# Indexes:
#  github_runner_pkey      | PRIMARY KEY btree (id)
#  github_runner_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  github_runner_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
