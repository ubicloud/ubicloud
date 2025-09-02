#  frozen_string_literal: true

require_relative "../../model"

class GithubCustomLabel < Sequel::Model
  plugin ResourceMethods

  def concurrency_limit_available?
    concurrency_limit = limits["concurrent_job_count"]
    return true if concurrency_limit.nil?

    current_runner_count = GithubRunner.where(installation_id: installation_id, label: label)
      .exclude(allocated_at: nil)
      .count

    current_runner_count < concurrency_limit
  end
end
