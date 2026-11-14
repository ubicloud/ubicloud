# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::GithubActiveWorkflowRunNexus do
  subject(:nx) {
    described_class.new(Strand.create_with_id(run_id, prog: "Github::GithubActiveWorkflowRunNexus", label: "start"))
  }

  let(:project) { Project.create(name: "test") }
  let(:installation) { GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-user", type: "User") }
  let(:repository) { GithubRepository.create(name: "ubicloud/ubicloud", installation_id: installation.id) }
  let(:ds) { DB[:github_active_workflow_run] }
  let(:run_id) {
    ds.insert(
      installation_id: installation.id,
      repository_id: repository.id,
      create_date: Date.today,
      run_id: 1234,
      run_attempt: 1,
      repository_name: repository.name,
      event: "push",
      status: "in_progress",
      display_title: "Test run",
      actor_login: "test-user",
      cache_scope: "main",
    )
  }

  describe "#start" do
    it "deletes the active workflow run and pops" do
      expect { nx.start }.to exit({"msg" => "exiting"})
      expect(ds.where(id: run_id).count).to eq 0
    end
  end

  describe "#destroy" do
    it "deletes the active workflow run and pops" do
      expect { nx.destroy }.to exit({"msg" => "exiting"})
      expect(ds.where(id: run_id).count).to eq 0
    end
  end
end
