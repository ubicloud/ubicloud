# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  semaphore :destroy

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
    values = {ubid: ubid, label: label, repository_name: repository_name, duration: duration, vm_ubid: vm.ubid, arch: vm.arch, cores: vm.cores}
    values[:vm_host_ubid] = vm.vm_host.ubid if vm.vm_host
    values[:vm_pool_ubid] = VmPool[vm.pool_id].ubid if vm.pool_id
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
      available_memory = session[:ssh_session].exec!("free | awk 'NR==2 {print $4}'").chomp
      "up"
    rescue
      "down"
    end
    aggregate_readings(previous_pulse: previous_pulse, reading: reading, data: {available_memory: available_memory})
  end

  def self.redacted_columns
    super + [:workflow_job]
  end
end
