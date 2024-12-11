# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  many_to_one :repository, key: :repository_id, class: :GithubRepository
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  semaphore :destroy, :skip_deregistration

  def run_url
    "http://github.com/#{repository_name}/actions/runs/#{workflow_job["run_id"]}"
  end

  def job_url
    "http://github.com/#{repository_name}/actions/runs/#{workflow_job["run_id"]}/job/#{workflow_job["id"]}"
  end

  def runner_url
    "http://github.com/#{repository_name}/settings/actions/runners/#{runner_id}" if runner_id
  end

  def display_state
    return vm.display_state if vm
    case strand&.label
    when "wait_vm_destroy" then "deleted"
    when "wait_concurrency_limit" then "reached_concurrency_limit"
    else "not_created"
    end
  end

  def log_duration(message, duration)
    values = {ubid: ubid, label: label, repository_name: repository_name, duration: duration}
    if vm
      values.merge!(vm_ubid: vm.ubid, arch: vm.arch, cores: vm.cores)
      values[:vm_host_ubid] = vm.vm_host.ubid if vm.vm_host
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

  def generate_cf_google_dns_dnsmasq_config
    <<~COMMAND
      sudo sed -i 's/^server=9.9.9.9@.*/server=2606:4700:4700::1111/' /vm/#{vm.inhost_name}/dnsmasq.conf
      sudo sed -i 's/^server=149.112.112.112@.*//' /vm/#{vm.inhost_name}/dnsmasq.conf
      sudo sed -i 's/^server=2620:fe::fe//' /vm/#{vm.inhost_name}/dnsmasq.conf
      sudo sed -i 's/^server=2620:fe::9/server=2001:4860:4860::8888/' /vm/#{vm.inhost_name}/dnsmasq.conf
      echo "all-servers" | sudo tee -a /vm/#{vm.inhost_name}/dnsmasq.conf
      sudo systemctl restart #{vm.inhost_name}-dnsmasq
    COMMAND
  end

  def self.redacted_columns
    super + [:workflow_job]
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
# Indexes:
#  github_runner_pkey      | PRIMARY KEY btree (id)
#  github_runner_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  github_runner_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
