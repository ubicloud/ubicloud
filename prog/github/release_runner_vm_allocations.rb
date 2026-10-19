# frozen_string_literal: true

class Prog::Github::ReleaseRunnerVmAllocations < Prog::Base
  label def wait
    GithubRunnerVmAllocation.release_expired
    nap Config.github_runner_vm_allocation_retention_seconds
  end
end
