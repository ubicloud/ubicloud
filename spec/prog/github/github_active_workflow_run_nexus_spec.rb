# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::GithubActiveWorkflowRunNexus do
  let(:project) { Project.create(name: "test") }
  let(:installation) { GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-user", type: "User") }
  let(:repository) { GithubRepository.create(installation_id: installation.id, name: "ubicloud/ubicloud") }
  let(:workflow_run_args) do
    {
      repository_name: "ubicloud/ubicloud",
      run_id: 111,
      run_attempt: 1,
      head_branch: "main",
      create_date: Time.now.utc.to_date,
      head_repository_full_name: "ubicloud/ubicloud",
      event: "push",
      status: "queued",
      display_title: "CI",
      commit_message: "cm",
      actor_login: "al",
      cache_scope: "main",
    }
  end
  let(:workflow_run) do
    GithubActiveWorkflowRun.create(installation_id: installation.id, repository_id: repository.id, **workflow_run_args)
  end
  let(:nx) {
    st = Strand.create_with_id(workflow_run, prog: "Github::GithubActiveWorkflowRunNexus", label: "start")
    described_class.new(st)
  }

  describe ".assemble" do
    it "creates the repository, the workflow run, and a strand" do
      described_class.assemble(installation:, default_branch: "main", **workflow_run_args)
      created = GithubActiveWorkflowRun.first
      expect(created.run_id).to eq(111)
      expect(created.installation_id).to eq(installation.id)
      repository = GithubRepository.first(installation_id: installation.id, name: "ubicloud/ubicloud")
      expect(created.repository_id).to eq(repository.id)
      expect(repository.default_branch).to eq("main")
      expect(repository.last_job_at).to be < GithubRepository::NO_RUNNER_LAST_JOB_CUTOFF
      expect(Strand[repository.id].prog).to eq("Github::GithubRepositoryNexus")
      expect(Strand[repository.id].label).to eq("wait")
      strands = Strand.where(prog: "Github::GithubActiveWorkflowRunNexus", label: "start").all
      expect(strands.count).to eq(1)
      expect(strands.first.schedule).to be_within(10).of(Time.now + 60 * 60)
    end

    it "uses an existing repository without updating it or creating a repository strand" do
      repository.update(last_job_at: Time.now - 60, default_branch: "master")
      last_job_at = repository.reload.last_job_at
      described_class.assemble(installation:, default_branch: "main", **workflow_run_args)
      expect(GithubActiveWorkflowRun.first.repository_id).to eq(repository.id)
      expect(GithubRepository.count).to eq(1)
      expect(repository.reload.last_job_at).to eq(last_job_at)
      expect(repository.default_branch).to eq("master")
      expect(Strand.where(prog: "Github::GithubRepositoryNexus").count).to eq(0)
      expect(GithubRepository.first(installation_id: installation.id, name: "ubicloud/ubicloud")).not_to be_nil
      strands = Strand.where(prog: "Github::GithubActiveWorkflowRunNexus", label: "start").all
      expect(strands.count).to eq(1)
      expect(strands.first.schedule).to be_within(10).of(Time.now + 60 * 60)
    end
  end

  describe "#start" do
    let(:client) { instance_double(Octokit::Client) }
    let(:attempt_path) { "repos/ubicloud/ubicloud/actions/runs/111/attempts/1" }

    before do
      allow(Github).to receive(:installation_client).with(123).and_return(client)
    end

    it "hops to destroy without checking GitHub if created more than 35 days ago" do
      workflow_run.update(created_at: Time.now - (60 * 60 * 24 * 35 + 10))
      expect(Github).not_to receive(:installation_client)
      expect { nx.start }.to hop("destroy")
    end

    it "updates the status and naps for an hour if the workflow run has not completed and the status has changed" do
      expect(client).to receive(:get).with(attempt_path).and_return({status: "in_progress", conclusion: nil, updated_at: Time.now})
      expect { nx.start }.to nap(60 * 60)
      workflow_run.reload
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.conclusion).to be_nil
      expect(workflow_run.completed_at).to be_nil
    end

    it "naps for an hour without updating the workflow run if the workflow run has not completed and the status has not changed" do
      workflow_run.update(status: "in_progress")
      expect(client).to receive(:get).with(attempt_path).and_return({status: "in_progress", conclusion: nil, updated_at: Time.now})
      expect(nx.github_active_workflow_run).not_to receive(:this)
      expect(nx.github_active_workflow_run).not_to receive(:update)
      expect { nx.start }.to nap(60 * 60)
      workflow_run.reload
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.completed_at).to be_nil
    end

    it "updates the workflow run and hops to destroy if the workflow run has completed" do
      updated_at = Time.at(Time.now.to_i - 30)
      expect(client).to receive(:get).with(attempt_path).and_return({status: "completed", conclusion: "success", updated_at:})
      expect { nx.start }.to hop("destroy")
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("success")
      expect(workflow_run.completed_at).to eq(updated_at)
    end

    it "updates the status and conclusion and naps for a day if the workflow run is newly awaiting approval" do
      expect(client).to receive(:get).with(attempt_path).and_return({status: "completed", conclusion: "action_required", updated_at: Time.now})
      expect { nx.start }.to nap(60 * 60 * 24)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(workflow_run.completed_at).to be_nil
    end

    it "updates the conclusion and naps for a day if only the conclusion has changed to action_required" do
      workflow_run.update(status: "completed")
      expect(client).to receive(:get).with(attempt_path).and_return({status: "completed", conclusion: "action_required", updated_at: Time.now})
      expect { nx.start }.to nap(60 * 60 * 24)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(workflow_run.completed_at).to be_nil
    end

    it "clears the action_required conclusion and naps for an hour if the approved workflow run is in progress" do
      workflow_run.update(status: "completed", conclusion: "action_required")
      expect(client).to receive(:get).with(attempt_path).and_return({status: "in_progress", conclusion: nil, updated_at: Time.now})
      expect { nx.start }.to nap(60 * 60)
      workflow_run.reload
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.conclusion).to be_nil
      expect(workflow_run.completed_at).to be_nil
    end

    it "naps for a day without updating the workflow run if the workflow run is still awaiting approval" do
      workflow_run.update(status: "completed", conclusion: "action_required")
      expect(client).to receive(:get).with(attempt_path).and_return({status: "completed", conclusion: "action_required", updated_at: Time.now})
      expect(nx.github_active_workflow_run).not_to receive(:this)
      expect(nx.github_active_workflow_run).not_to receive(:update)
      expect { nx.start }.to nap(60 * 60 * 24)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(workflow_run.completed_at).to be_nil
    end

    it "hops to destroy if the workflow run is not found" do
      expect(client).to receive(:get).with(attempt_path).and_raise(Octokit::NotFound.new({status: 404}))
      expect { nx.start }.to hop("destroy")
    end

    it "logs and naps for an hour on other client errors" do
      expect(client).to receive(:get).with(attempt_path).and_raise(Octokit::Forbidden.new({status: 403}))
      expect(Clog).to receive(:emit).with("Could not fetch the workflow run", instance_of(Hash)).and_call_original
      expect { nx.start }.to nap(60 * 60)
    end

    it "logs and naps for a day on errors if the workflow run is awaiting approval" do
      workflow_run.update(status: "completed", conclusion: "action_required")
      expect(client).to receive(:get).with(attempt_path).and_raise(Octokit::InternalServerError)
      expect(Clog).to receive(:emit).with("Could not fetch the workflow run", instance_of(Hash)).and_call_original
      expect { nx.start }.to nap(60 * 60 * 24)
    end

    it "logs and naps for an hour on server errors" do
      expect(client).to receive(:get).with(attempt_path).and_raise(Octokit::InternalServerError)
      expect(Clog).to receive(:emit).with("Could not fetch the workflow run", instance_of(Hash)).and_call_original
      expect { nx.start }.to nap(60 * 60)
    end
  end

  describe "#destroy" do
    it "naps if there are runners still associated with the workflow run" do
      GithubRunner.create(installation_id: installation.id, repository_id: repository.id, repository_name: "ubicloud/ubicloud", label: "ubicloud", run_id: 111, run_attempt: 1)
      expect { nx.destroy }.to nap(10 * 60)
    end

    it "destroys the workflow run and pops" do
      expect { nx.destroy }.to exit({"msg" => "active workflow run finished"})
      expect(GithubActiveWorkflowRun[workflow_run.id]).to be_nil
    end
  end
end
