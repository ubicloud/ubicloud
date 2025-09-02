#  frozen_string_literal: true

require_relative "../../model"

class GithubCustomLabel < Sequel::Model
  plugin ResourceMethods

  def concurrency_limit_available?
    concurrent_runner_count_limit.nil? || allocated_runner_count < concurrent_runner_count_limit
  end
end
