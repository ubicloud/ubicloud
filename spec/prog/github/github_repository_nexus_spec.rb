# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::GithubRepositoryNexus do
  subject(:nx) {
    described_class.new(Strand.new).tap {
      it.instance_variable_set(:@github_repository, github_repository)
    }
  }

  let(:github_repository) {
    GithubRepository.new(name: "ubicloud/ubicloud", last_job_at: Time.now).tap {
      it.id = "31b9c46a-602a-8616-ae2f-41775cb592dd"
    }
  }

  describe ".assemble" do
    it "creates github repository or updates last_job_at if the repository exists" do
      project = Project.create_with_id(name: "default")
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      expect {
        described_class.assemble(installation, "ubicloud/ubicloud", "master")
      }.to change(GithubRepository, :count).from(0).to(1)
      now = Time.now.round(6)
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      st = described_class.assemble(installation, "ubicloud/ubicloud", "main")
      expect(GithubRepository.count).to eq(1)
      expect(Strand.count).to eq(1)
      expect(st.subject.last_job_at).to eq(now)
      expect(st.subject.default_branch).to eq("main")
      described_class.assemble(installation, "ubicloud/ubicloud", nil)
      expect(st.subject.default_branch).to eq("main")
    end
  end

  describe ".check_queued_jobs" do
    let(:client) { instance_double(Octokit::Client) }

    before do
      allow(Github).to receive(:installation_client).and_return(client)
      allow(client).to receive(:auto_paginate=)
      installation = instance_double(GithubInstallation, installation_id: "123")
      expect(github_repository).to receive(:installation).and_return(installation).at_least(:once)
      expect(installation).to receive(:project).and_return(instance_double(Project, active?: true)).at_least(:once)
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

    it "does not poll jobs if the project is not active" do
      expect(github_repository.installation.project).to receive(:active?).and_return(false)
      nx.check_queued_jobs
      expect(nx.polling_interval).to eq(24 * 60 * 60)
    end
  end

  describe ".cleanup_cache" do
    let(:blob_storage_client) { instance_double(Aws::S3::Client) }

    before do
      project = Project.create_with_id(name: "test")
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
      github_repository.installation_id = installation.id
      github_repository.save_changes
      allow(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
    end

    def create_cache_entry(**args)
      defaults = {key: "k#{Random.rand}", version: "v1", scope: "main", repository_id: github_repository.id, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b", committed_at: Time.now}
      GithubCacheEntry.create(defaults.merge!(args))
    end

    it "deletes cache entries that not accessed in the last 7 days" do
      cache_entry = create_cache_entry(last_accessed_at: Time.now - 6 * 24 * 60 * 60)
      ten_days_old = create_cache_entry(last_accessed_at: Time.now - 10 * 24 * 60 * 60)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: ten_days_old.blob_key)
      nx.cleanup_cache
      expect(cache_entry).to exist
      expect(ten_days_old).not_to exist
    end

    it "deletes cache entries created 30 minutes ago but not committed yet" do
      cache_entry = create_cache_entry(created_at: Time.now - 15 * 60, committed_at: nil)
      thirty_five_minutes_old = create_cache_entry(created_at: Time.now - 35 * 60, committed_at: nil)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: thirty_five_minutes_old.blob_key)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket: github_repository.bucket_name, key: thirty_five_minutes_old.blob_key, upload_id: thirty_five_minutes_old.upload_id)
      nx.cleanup_cache
      expect(cache_entry).to exist
      expect(thirty_five_minutes_old).not_to exist
    end

    it "deletes cache entries that older than 7 days not accessed yet" do
      six_days_old = create_cache_entry(last_accessed_at: nil, created_at: Time.now - 6 * 24 * 60 * 60)
      ten_days_old = create_cache_entry(last_accessed_at: nil, created_at: Time.now - 10 * 24 * 60 * 60)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket: github_repository.bucket_name, key: six_days_old.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: ten_days_old.blob_key)
      nx.cleanup_cache
      expect(six_days_old).to exist
      expect(ten_days_old).not_to exist
    end

    it "deletes oldest cache entries if the total usage exceeds the default limit" do
      twenty_nine_gib_cache = create_cache_entry(created_at: Time.now - 10 * 60, size: 29 * 1024 * 1024 * 1024)
      two_gib_cache = create_cache_entry(created_at: Time.now - 11 * 60, size: 2 * 1024 * 1024 * 1024)
      three_gib_cache = create_cache_entry(created_at: Time.now - 12 * 60, size: 3 * 1024 * 1024 * 1024)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket: github_repository.bucket_name, key: twenty_nine_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: two_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: three_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "excludes uncommitted cache entries" do
      thirty_two_gib_cache = create_cache_entry(created_at: Time.now - 10 * 60, size: 32 * 1024 * 1024 * 1024)
      create_cache_entry(created_at: Time.now - 13 * 60, size: nil)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: thirty_two_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "deletes oldest cache entries if the total usage exceeds the custom limit" do
      github_repository.installation.project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerCacheStorage"]["id"], value: 20)
      nine_gib_cache = create_cache_entry(created_at: Time.now - 10 * 60, size: 19 * 1024 * 1024 * 1024)
      two_gib_cache = create_cache_entry(created_at: Time.now - 11 * 60, size: 2 * 1024 * 1024 * 1024)
      three_gib_cache = create_cache_entry(created_at: Time.now - 12 * 60, size: 3 * 1024 * 1024 * 1024)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket: github_repository.bucket_name, key: nine_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: two_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket: github_repository.bucket_name, key: three_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "deletes blob storage if there are no cache entries" do
      expect(github_repository).to receive(:destroy_blob_storage)
      nx.cleanup_cache
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
    it "checks queued jobs and cache usage then naps" do
      expect(github_repository).to receive(:access_key).and_return("key")
      expect(nx).to receive(:check_queued_jobs)
      expect(nx).to receive(:cleanup_cache)
      expect { nx.wait }.to nap(5 * 60)
    end

    it "does not check queued jobs but check cache usage if 6 hours passed from the last job" do
      expect(github_repository).to receive(:access_key).and_return("key")
      expect(github_repository).to receive(:last_job_at).and_return(Time.now - 7 * 60 * 60)
      expect(nx).not_to receive(:check_queued_jobs)
      expect(nx).to receive(:cleanup_cache)
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

    it "does not poll if it is disabled" do
      expect(Config).to receive(:enable_github_workflow_poller).and_return(false)
      expect(nx).not_to receive(:check_queued_jobs)

      expect { nx.wait }.to nap(5 * 60)
    end
  end

  describe "#destroy" do
    it "does not destroy if has active runner" do
      expect(github_repository).to receive(:runners).and_return([instance_double(GithubRunner)])
      expect { nx.destroy }.to nap(5 * 60)
    end

    it "destroys blob storage if has one" do
      github_repository.update(access_key: "access_key")
      GithubCacheEntry.create(repository_id: github_repository.id, key: "k1", version: "v1", scope: "main", upload_id: "upload-123", committed_at: Time.now, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b")
      blob_storage_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
      expect(blob_storage_client).to receive(:delete_object)
      expect(github_repository).to receive(:destroy_blob_storage)

      expect { nx.destroy }.to exit({"msg" => "github repository destroyed"})
    end

    it "deletes resource and pops" do
      expect(nx).to receive(:decr_destroy)
      expect(github_repository).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "github repository destroyed"})
    end
  end
end
