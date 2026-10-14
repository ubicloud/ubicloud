# frozen_string_literal: true

class Prog::Github::ReconcileRunnerCapacity < Prog::Base
  label def wait
    GithubRunner.adopt_capacity
    GithubRunnerCapacity.reconcile
    nap Config.github_runner_capacity_reconcile_seconds
  end
end
