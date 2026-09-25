# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe DailyPartitionMethods do
  let(:day) { Time.now.utc.to_date + 90 }

  it "configures the partition name and type of the model" do
    expect(DeletedRecord.partition_type).to eq :timestamptz
    expect(GithubCompletedWorkflowRun.partition_type).to eq :date
    expect(GithubCompletedWorkflowJob.partition_name(Date.new(2026, 5, 14))).to eq "github_completed_workflow_job_2026_05_14"
  end

  it "only treats tables named for a day as partitions" do
    expect(GithubCompletedWorkflowRun.partition_name_regexp.match?("github_completed_workflow_run_2026_05_14")).to be true
    expect(GithubCompletedWorkflowRun.partition_name_regexp.match?("github_completed_workflow_run_2026_05_14_old")).to be false
  end

  it "creates date partitions that route rows for their day" do
    GithubCompletedWorkflowRun.create_partition(day)
    GithubCompletedWorkflowRun.create_partition(day + 1)
    expect(GithubCompletedWorkflowRun.partition_days).to include(day, day + 1)

    now = Time.now
    GithubCompletedWorkflowRun.dataset.insert(repository_id: GithubRepository.generate_uuid, run_id: 1, run_attempt: 1, create_date: day, installation_id: GithubInstallation.generate_uuid, created_at: now, completed_at: now, head_branch: "main", head_repository_full_name: "a/b", event: "push", status: "completed", conclusion: "success", display_title: "t", commit_message: "m", actor_login: "u", duration: 1)
    expect(DB[GithubCompletedWorkflowRun.partition_name(day).to_sym].count).to eq 1
    expect(DB[GithubCompletedWorkflowRun.partition_name(day + 1).to_sym].count).to eq 0
  end

  it "drops a date partition" do
    GithubCompletedWorkflowJob.create_partition(day)
    GithubCompletedWorkflowJob.drop_partition(day)
    expect(GithubCompletedWorkflowJob.partition_days).not_to include(day)
  end
end
