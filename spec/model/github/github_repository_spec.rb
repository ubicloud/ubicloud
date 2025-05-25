# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRepository do
  subject(:github_repository) { described_class.new(name: "test", access_key: "my-token-id").tap { it.id = "8823102a-2d5c-8e16-ac04-c60f1b6b9984" } }

  let(:blob_storage_client) { instance_double(Aws::S3::Client) }
  let(:cloudflare_client) { instance_double(CloudflareClient) }

  before do
    allow(CloudflareClient).to receive(:new).and_return(cloudflare_client)
    allow(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
  end

  describe ".destroy_blob_storage" do
    it "deletes the bucket and token" do
      expect(blob_storage_client).to receive(:delete_bucket).with(bucket: "gph0hh0ahdbj6ng2cc3rvdecr8")
      expect(github_repository).to receive(:this).and_return(github_repository)
      expect(github_repository).to receive(:update).with(access_key: nil, secret_key: nil, session_token: nil, last_token_refreshed_at: nil)
      github_repository.destroy_blob_storage
    end

    it "succeeds if the bucket is already deleted" do
      expect(blob_storage_client).to receive(:delete_bucket).and_raise(Aws::S3::Errors::NoSuchBucket.new(nil, nil))
      expect(github_repository).to receive(:this).and_return(github_repository)
      expect(github_repository).to receive(:update).with(access_key: nil, secret_key: nil, session_token: nil, last_token_refreshed_at: nil)
      github_repository.destroy_blob_storage
    end
  end

  describe ".after_destroy" do
    it "deletes the blob storage and cache entries" do
      github_repository.save_changes
      GithubCacheEntry.create_with_id(repository_id: github_repository.id, key: "k1", version: "v1", scope: "main", upload_id: "upload-123", committed_at: Time.now, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b")
      expect(blob_storage_client).to receive(:delete_object)
      expect(github_repository).to receive(:destroy_blob_storage)

      github_repository.destroy
    end

    it "do not delete the blob storage if does not have one" do
      github_repository.save_changes
      expect(github_repository).to receive(:access_key)
      expect(github_repository).not_to receive(:destroy_blob_storage)

      github_repository.destroy
    end
  end

  describe ".setup_blob_storage" do
    it "creates a bucket and token" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur")
      expect(blob_storage_client).to receive(:create_bucket).with({bucket: "gph0hh0ahdbj6ng2cc3rvdecr8", create_bucket_configuration: {location_constraint: "weur"}})
      expect(cloudflare_client).to receive(:create_temporary_token).with("gph0hh0ahdbj6ng2cc3rvdecr8", "object-read-write", 432000).and_return(["test-key", "test-secret", "test-token"])
      expect(github_repository).to receive(:update).with(access_key: "test-key", secret_key: "test-secret", session_token: "test-token", last_token_refreshed_at: instance_of(Time))
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end

    it "succeeds if the bucket already exists and access key does not exist" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur")
      expect(blob_storage_client).to receive(:create_bucket).and_raise(Aws::S3::Errors::BucketAlreadyOwnedByYou.new(nil, nil))
      expect(cloudflare_client).to receive(:create_temporary_token).with("gph0hh0ahdbj6ng2cc3rvdecr8", "object-read-write", 432000).and_return(["test-key", "test-secret", "test-token"])
      expect(github_repository).to receive(:access_key).and_return(nil)
      expect(github_repository).to receive(:update).with(access_key: "test-key", secret_key: "test-secret", session_token: "test-token", last_token_refreshed_at: instance_of(Time))
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end

    it "succeeds if the access and secret key and token already exist" do
      expect(github_repository).to receive(:access_key).and_return("test-key")
      expect(github_repository).to receive(:secret_key).and_return(Digest::SHA256.hexdigest("test-secret"))
      expect(github_repository).to receive(:session_token).and_return("test-token")
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end
  end

  describe ".refresh_blob_storage_token" do
    it "create a new temporary token" do
      expect(cloudflare_client).to receive(:create_temporary_token).with("gph0hh0ahdbj6ng2cc3rvdecr8", "object-read-write", 432000).and_return(["test-key", "test-secret", "test-token"])
      expect(github_repository).to receive(:update).with(access_key: "test-key", secret_key: "test-secret", session_token: "test-token", last_token_refreshed_at: instance_of(Time))
      github_repository.refresh_blob_storage_token
    end
  end
end
