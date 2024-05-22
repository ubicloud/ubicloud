# frozen_string_literal: true

class Serializers::GithubRunner < Serializers::Base
  def self.serialize_internal(runner, options = {})
    {
      id: runner.id,
      ubid: runner.ubid,
      label: runner.label,
      repository_name: runner.repository_name,
      runner_id: runner.runner_id,
      runner_url: runner.runner_url,
      workflow_job: runner.workflow_job ? {
        run_id: runner.workflow_job["run_id"],
        run_url: runner.run_url,
        job_id: runner.workflow_job["id"],
        job_name: runner.workflow_job["name"],
        job_url: runner.job_url,
        workflow_name: runner.workflow_job["workflow_name"],
        head_branch: runner.workflow_job["head_branch"]
      } : nil,
      state: runner.display_state
    }
  end
end
