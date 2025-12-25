# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::GithubRepositoryNexus do
  subject(:nx) {
    st = Strand.create_with_id(repository, prog: "Github::GithubRepositoryNexus", label: "wait")
    described_class.new(st)
  }

  let(:project) { Project.create(name: "test") }
  let(:installation) { GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-user", type: "User") }
  let(:repository) {
    GithubRepository.create(name: "ubicloud/ubicloud", last_job_at: Time.now, installation_id: installation.id)
  }

  let(:now) { Time.now.round }
  let(:client) { instance_double(Octokit::Client) }

  before do
    allow(Github).to receive(:installation_client).and_return(client)
    allow(client).to receive(:auto_paginate=)
    allow(Time).to receive(:now).and_return(now)
  end

  describe ".assemble" do
    it "creates github repository or updates last_job_at if the repository exists" do
      expect {
        described_class.assemble(installation, "ubicloud/ubicloud", "master")
      }.to change(GithubRepository, :count).from(0).to(1)
      repository = described_class.assemble(installation, "ubicloud/ubicloud", "main").subject
      expect(GithubRepository.count).to eq(1)
      expect(Strand.count).to eq(1)
      expect(repository.last_job_at).to eq(now)
      expect(repository.default_branch).to eq("main")
      described_class.assemble(installation, "ubicloud/ubicloud", nil)
      expect(repository.default_branch).to eq("main")
    end
  end

  describe ".check_queued_jobs" do
    it "creates extra runner if needed" do
      GithubCustomLabel.create(installation_id: installation.id, name: "custom-label-1", alias_for: "ubicloud-standard-4")
      GithubCustomLabel.create(installation_id: installation.id, name: "custom-label-2", alias_for: "ubicloud-standard-8")

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
        {status: "queued", labels: ["custom-label-1"]},
        {status: "queued", labels: ["custom-label-2"]},
        {status: "failed", labels: ["ubicloud"]}
      ]})
      expect(client).to receive(:workflow_run_attempt_jobs).with("ubicloud/ubicloud", 2, 1).and_return({jobs: [
        {status: "queued", labels: ["ubicloud"]}
      ]})

      # Create existing runners (idle, no workflow_job) - these reduce the number of new runners needed
      [["ubicloud"], ["ubicloud-standard-8"], ["ubicloud-standard-4", "custom-label-1"]].each do |label, actual_label|
        GithubRunner.create(installation_id: installation.id, repository_id: repository.id, repository_name: "ubicloud/ubicloud", label:, actual_label: actual_label || label)
      end

      expect { nx.check_queued_jobs }
        .to change(GithubRunner, :count).from(3).to(7)
        .and change { GithubRunner.where(label: "ubicloud").count }.from(1).to(3)
        .and change { GithubRunner.where(label: "ubicloud-standard-4").count }.from(1).to(2)
        .and change { GithubRunner.where(label: "ubicloud-standard-8").count }.from(1).to(2)
      expect(nx.polling_interval).to eq(5 * 60)
    end

    it "naps until the resets_at if remaining quota is low" do
      expect(client).to receive(:repository_workflow_runs).and_return({workflow_runs: []})
      expect(client).to receive(:rate_limit).and_return(instance_double(Octokit::RateLimit, remaining: 8, limit: 100, resets_at: now + 8 * 60)).at_least(:once)
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
      project.update(visible: false)
      nx.check_queued_jobs
      expect(nx.polling_interval).to eq(24 * 60 * 60)
    end
  end

  describe ".cleanup_cache" do
    let(:blob_storage_client) { instance_double(Aws::S3::Client) }
    let(:bucket) { repository.bucket_name }

    before do
      allow(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
    end

    def create_cache_entry(**args)
      defaults = {key: "k#{Random.rand}", version: "v1", scope: "main", repository_id: repository.id, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b", committed_at: Time.now}
      GithubCacheEntry.create(defaults.merge!(args))
    end

    it "deletes cache entries that not accessed in the last 7 days" do
      cache_entry = create_cache_entry(last_accessed_at: now - 6 * 24 * 60 * 60)
      ten_days_old = create_cache_entry(last_accessed_at: now - 10 * 24 * 60 * 60)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: ten_days_old.blob_key)
      nx.cleanup_cache
      expect(cache_entry).to exist
      expect(ten_days_old).not_to exist
    end

    it "deletes cache entries created 30 minutes ago but not committed yet" do
      cache_entry = create_cache_entry(created_at: now - 15 * 60, committed_at: nil)
      thirty_five_minutes_old = create_cache_entry(created_at: now - 35 * 60, committed_at: nil)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: thirty_five_minutes_old.blob_key)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket:, key: thirty_five_minutes_old.blob_key, upload_id: thirty_five_minutes_old.upload_id)
      nx.cleanup_cache
      expect(cache_entry).to exist
      expect(thirty_five_minutes_old).not_to exist
    end

    it "deletes cache entries that older than 7 days not accessed yet" do
      six_days_old = create_cache_entry(last_accessed_at: nil, created_at: now - 6 * 24 * 60 * 60)
      ten_days_old = create_cache_entry(last_accessed_at: nil, created_at: now - 10 * 24 * 60 * 60)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket:, key: six_days_old.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: ten_days_old.blob_key)
      nx.cleanup_cache
      expect(six_days_old).to exist
      expect(ten_days_old).not_to exist
    end

    it "deletes oldest cache entries if the total usage exceeds the default limit" do
      twenty_nine_gib_cache = create_cache_entry(created_at: now - 10 * 60, size: 29 * 1024 * 1024 * 1024)
      two_gib_cache = create_cache_entry(created_at: now - 11 * 60, size: 2 * 1024 * 1024 * 1024)
      three_gib_cache = create_cache_entry(created_at: now - 12 * 60, size: 3 * 1024 * 1024 * 1024)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket:, key: twenty_nine_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: two_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: three_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "excludes uncommitted cache entries" do
      thirty_two_gib_cache = create_cache_entry(created_at: now - 10 * 60, size: 32 * 1024 * 1024 * 1024)
      create_cache_entry(created_at: now - 13 * 60, size: nil)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: thirty_two_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "deletes oldest cache entries if the total usage exceeds the custom limit" do
      repository.installation.project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerCacheStorage"]["id"], value: 20)
      nine_gib_cache = create_cache_entry(created_at: now - 10 * 60, size: 19 * 1024 * 1024 * 1024)
      two_gib_cache = create_cache_entry(created_at: now - 11 * 60, size: 2 * 1024 * 1024 * 1024)
      three_gib_cache = create_cache_entry(created_at: now - 12 * 60, size: 3 * 1024 * 1024 * 1024)
      expect(blob_storage_client).not_to receive(:delete_object).with(bucket:, key: nine_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: two_gib_cache.blob_key)
      expect(blob_storage_client).to receive(:delete_object).with(bucket:, key: three_gib_cache.blob_key)
      nx.cleanup_cache
    end

    it "deletes blob storage if there are no cache entries" do
      expect(nx.github_repository).to receive(:destroy_blob_storage)
      nx.cleanup_cache
    end
  end

  describe "#wait" do
    it "checks queued jobs and cache usage then naps" do
      repository.update(access_key: "key")
      expect(nx).to receive(:check_queued_jobs)
      expect(nx).to receive(:cleanup_cache)
      expect { nx.wait }.to nap(5 * 60)
    end

    it "does not check queued jobs but check cache usage if 6 hours passed from the last job" do
      repository.update(access_key: "key", last_job_at: now - 7 * 60 * 60)
      expect(nx).not_to receive(:check_queued_jobs)
      expect(nx).to receive(:cleanup_cache)
      expect { nx.wait }.to nap(15 * 60)
    end

    it "does not destroys repository and if not found but has active runners" do
      GithubRunner.create(repository_id: repository.id, repository_name: "ubicloud/ubicloud", label: "ubicloud")
      expect(nx).to receive(:check_queued_jobs).and_raise(Octokit::NotFound)
      expect { nx.wait }.to nap(5 * 60)
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(0)
    end

    it "destroys repository and if not found" do
      expect(nx).to receive(:check_queued_jobs).and_raise(Octokit::NotFound)
      expect { nx.wait }.to nap(0)
      expect(Semaphore.where(strand_id: repository.id, name: "destroy").count).to eq(1)
    end

    it "does not poll if it is disabled" do
      expect(Config).to receive(:enable_github_workflow_poller).and_return(false)
      expect(nx).not_to receive(:check_queued_jobs)

      expect { nx.wait }.to nap(5 * 60)
    end
  end

  describe "#destroy" do
    it "does not destroy if has active runner" do
      GithubRunner.create(repository_id: repository.id, repository_name: "ubicloud/ubicloud", label: "ubicloud")
      expect { nx.destroy }.to nap(5 * 60)
    end

    it "destroys blob storage if has one" do
      repository.update(access_key: "access_key")
      GithubCacheEntry.create(repository_id: repository.id, key: "k1", version: "v1", scope: "main", upload_id: "upload-123", committed_at: Time.now, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b")
      blob_storage_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
      expect(blob_storage_client).to receive(:delete_object)
      expect(nx.github_repository).to receive(:destroy_blob_storage)

      expect { nx.destroy }.to exit({"msg" => "github repository destroyed"})
    end

    it "deletes resource and pops" do
      expect(nx).to receive(:decr_destroy)
      expect { nx.destroy }.to exit({"msg" => "github repository destroyed"})
      expect(repository.exists?).to be false
    end
  end
end
