# frozen_string_literal: true

class Prog::Github::ReleaseRunnerVmAllocations < Prog::Base
  label def wait
    GithubRunnerVmAllocation.release_expired

    nap 60
  end
end
