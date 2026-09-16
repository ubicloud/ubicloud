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
    end
  end

  describe "#start" do
    it "naps until shortly after deadline" do
      secs = 60 * 60 * 24 * 35 + 60
      expect { nx.start }.to nap((secs - 10)...(secs + 10))

      nx.github_active_workflow_run.update(created_at: Time.now - (60 * 60 * 24 * 35 - 10))
      expect { nx.start }.to nap(60...80)
    end

    it "hops to destroy if created more than 35 days ago" do
      workflow_run.update(created_at: Time.now - (60 * 60 * 24 * 35 + 10))
      expect { nx.start }.to hop("destroy")
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
