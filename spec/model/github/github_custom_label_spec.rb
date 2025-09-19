# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubCustomLabel do
  describe "#concurrency_limit_available?" do
    it "returns true if the concurrent_runner_count_limit is nil" do
      label = described_class.new(concurrent_runner_count_limit: nil, allocated_runner_count: 0)
      expect(label).to be_concurrency_limit_available
    end

    it "returns true if the allocated_runner_count is less than the concurrent_runner_count_limit" do
      label = described_class.new(concurrent_runner_count_limit: 10, allocated_runner_count: 9)
      expect(label).to be_concurrency_limit_available
    end

    it "returns false if the allocated_runner_count is greater than the concurrent_runner_count_limit" do
      label = described_class.new(concurrent_runner_count_limit: 10, allocated_runner_count: 11)
      expect(label).not_to be_concurrency_limit_available
    end
  end
end
