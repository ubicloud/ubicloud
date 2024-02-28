# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::GithubRepositoryNexus do
  subject(:nx) {
    described_class.new(Strand.new).tap {
      _1.instance_variable_set(:@github_repository, github_repository)
    }
  }

  let(:github_repository) {
    GithubRepository.new(name: "ubicloud/ubicloud", last_job_at: Time.now).tap {
      _1.id = "31b9c46a-602a-8616-ae2f-41775cb592dd"
    }
  }

  describe ".assemble" do
    it "creates github repository or updates last_job_at if the repository exists" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      expect {
        described_class.assemble(installation, "ubicloud/ubicloud")
      }.to change(GithubRepository, :count).from(0).to(1)
      now = Time.now.round(6)
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      st = described_class.assemble(installation, "ubicloud/ubicloud")
      expect(GithubRepository.count).to eq(1)
      expect(Strand.count).to eq(1)
      expect(st.subject.last_job_at).to eq(now)
    end
  end

  describe ".check_queued_jobs" do
    let(:client) { instance_double(Octokit::Client) }

    before do
      allow(Github).to receive(:installation_client).and_return(client)
      expect(client).to receive(:auto_paginate=)
      expect(github_repository).to receive(:installation).and_return(instance_double(GithubInstallation, installation_id: "123")).at_least(:once)
    end

    it "creates extra runner if needed" do
      expect(client).to receive(:repository_workflow_runs).and_return({workflow_runs: [
        {id: 1, run_attempt: 2, status: "queued"},
        {id: 2, run_attempt: 1, status: "queued"}
      ]})
      expect(client).to receive(:rate_limit).and_return(instance_double(Octokit::RateLimit, remaining: 100, limit: 100)).at_least(:once)
      expect(client).to receive(:workflow_run_attempt_jobs).with("ubicloud/ubicloud", 1, 2).and_return({jobs: [
        {status: "queued", labels: ["ubuntu-latest"]},
        {status: "queued", labels: ["ubicloud"]},
        {status: "queued", labels: ["ubicloud"]},
        {status: "queued", labels: ["ubicloud-standard-4"]},
        {status: "queued", labels: ["ubicloud-standard-8"]},
        {status: "failed", labels: ["ubicloud"]}
      ]})
      expect(client).to receive(:workflow_run_attempt_jobs).with("ubicloud/ubicloud", 2, 1).and_return({jobs: [
        {status: "queued", labels: ["ubicloud"]}
      ]})
      expect(github_repository).to receive(:runners_dataset).and_return(instance_double(Sequel::Dataset)).at_least(:once)
      expect(github_repository.runners_dataset).to receive(:where).with(label: "ubicloud", workflow_job: nil).and_return([instance_double(GithubRunner)])
      expect(github_repository.runners_dataset).to receive(:where).with(label: "ubicloud-standard-4", workflow_job: nil).and_return([])
      expect(github_repository.runners_dataset).to receive(:where).with(label: "ubicloud-standard-8", workflow_job: nil).and_return([instance_double(GithubRunner)])
      expect(Prog::Vm::GithubRunner).to receive(:assemble).with(github_repository.installation, repository_name: "ubicloud/ubicloud", label: "ubicloud").twice
      expect(Prog::Vm::GithubRunner).to receive(:assemble).with(github_repository.installation, repository_name: "ubicloud/ubicloud", label: "ubicloud-standard-4")
      expect(Prog::Vm::GithubRunner).not_to receive(:assemble).with(github_repository.installation, repository_name: "ubicloud/ubicloud", label: "ubicloud-standard-8")
      nx.check_queued_jobs
      expect(nx.polling_interval).to eq(5 * 60)
    end

    it "naps until the resets_at if remaining quota is low" do
      expect(client).to receive(:repository_workflow_runs).and_return({workflow_runs: []})
      now = Time.now
      expect(client).to receive(:rate_limit).and_return(instance_double(Octokit::RateLimit, remaining: 8, limit: 100, resets_at: now + 8 * 60)).at_least(:once)
      expect(Time).to receive(:now).and_return(now)
      nx.check_queued_jobs
      expect(nx.polling_interval).to eq(8 * 60)
    end

    it "increases polling interval if remaining quota is lower than 0.5" do
      expect(client).to receive(:repository_workflow_runs).and_return({workflow_runs: []})
      expect(client).to receive(:rate_limit).and_return(instance_double(Octokit::RateLimit, remaining: 40, limit: 100)).at_least(:once)
      nx.check_queued_jobs
      expect(nx.polling_interval).to eq(15 * 60)
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx).to receive(:register_deadline)
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#wait" do
    it "checks queued jobs and naps" do
      expect(nx).to receive(:check_queued_jobs)
      expect { nx.wait }.to nap(5 * 60)
    end

    it "does not check queued jobs if 6 hours passed from the last job" do
      expect(github_repository).to receive(:last_job_at).and_return(Time.now - 7 * 60 * 60)
      expect(nx).not_to receive(:check_queued_jobs)
      expect { nx.wait }.to nap(15 * 60)
    end

    it "does not destroys repository and if not found but has active runners" do
      expect(nx).to receive(:check_queued_jobs).and_raise(Octokit::NotFound)
      expect(github_repository).to receive(:runners).and_return([instance_double(GithubRunner)])
      expect(github_repository).not_to receive(:incr_destroy)
      expect { nx.wait }.to nap(5 * 60)
    end

    it "destroys repository and if not found" do
      expect(nx).to receive(:check_queued_jobs).and_raise(Octokit::NotFound)
      expect(github_repository).to receive(:incr_destroy)
      expect { nx.wait }.to nap(0)
    end
  end

  describe "#destroy" do
    it "does not destroy if has active runner" do
      expect(github_repository).to receive(:runners).and_return([instance_double(GithubRunner)])
      expect { nx.destroy }.to nap(5 * 60)
    end

    it "deletes resource and pops" do
      expect(nx).to receive(:decr_destroy)
      expect(github_repository).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "github repository destroyed"})
    end
  end
end
