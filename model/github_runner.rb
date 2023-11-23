# frozen_string_literal: true

require_relative "../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods

  include SemaphoreMethods
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
end
