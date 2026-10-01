# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubCompletedWorkflowJob do
  let(:job) { described_class.new(job_started_at: Time.utc(2026, 9, 1, 10, 0, 0)) }

  describe "#github_duration" do
    it "returns seconds between when GitHub reports the job started and completed" do
      job.job_completed_at = Time.utc(2026, 9, 1, 10, 2, 30)
      expect(job.github_duration).to eq 150
    end

    it "returns nil if GitHub did not report a completion time" do
      expect(job.github_duration).to be_nil
    end
  end
end
