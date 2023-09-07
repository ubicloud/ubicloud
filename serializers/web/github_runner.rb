# frozen_string_literal: true

class Serializers::Web::GithubRunner < Serializers::Base
  def self.base(runner)
    {
      id: runner.id,
      ubid: runner.ubid,
      label: runner.label,
      repository_name: runner.repository_name,
      runner_id: runner.runner_id,
      runner_url: runner.runner_url,
      run_id: runner.run_id,
      run_url: runner.run_url,
      job_id: runner.job_id,
      job_name: runner.job_name,
      job_url: runner.job_url,
      workflow_name: runner.workflow_name,

      vm: runner.vm ? {
        name: runner.vm.name,
        path: runner.vm.path,
        state: runner.vm.display_state
      } : nil
    }
  end

  structure(:default) do |runner|
    base(runner)
  end
end
