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
      uploads = instance_double(Aws::S3::Types::ListMultipartUploadsOutput, uploads: [
        instance_double(Aws::S3::Types::MultipartUpload, key: "test-key", upload_id: "test-upload-id")
      ])
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(uploads)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket: "gph0hh0ahdbj6ng2cc3rvdecr8", key: "test-key", upload_id: "test-upload-id")
      expect(blob_storage_client).to receive(:delete_bucket).with(bucket: "gph0hh0ahdbj6ng2cc3rvdecr8")
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key)
      expect(github_repository).to receive(:this).and_return(github_repository)
      expect(github_repository).to receive(:update).with(access_key: nil, secret_key: nil)
      github_repository.destroy_blob_storage
    end

    it "succeeds if the bucket is already deleted" do
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(instance_double(Aws::S3::Types::ListMultipartUploadsOutput, uploads: []))
      expect(blob_storage_client).to receive(:delete_bucket).and_raise(Aws::S3::Errors::NoSuchBucket.new(nil, nil))
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key)
      expect(github_repository).to receive(:this).and_return(github_repository)
      expect(github_repository).to receive(:update).with(access_key: nil, secret_key: nil)
      github_repository.destroy_blob_storage
    end
  end

  describe ".setup_blob_storage" do
    it "creates a bucket and token" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur", github_cache_blob_storage_account_id: "123")
      expect(blob_storage_client).to receive(:create_bucket).with({bucket: "gph0hh0ahdbj6ng2cc3rvdecr8", create_bucket_configuration: {location_constraint: "weur"}})
      expected_policy = [
        {
          "effect" => "allow",
          "permission_groups" => [{"id" => "2efd5506f9c8494dacb1fa10a3e7d5b6", "name" => "Workers R2 Storage Bucket Item Write"}],
          "resources" => {"com.cloudflare.edge.r2.bucket.123_default_gph0hh0ahdbj6ng2cc3rvdecr8" => "*"}
        }
      ]
      expect(cloudflare_client).to receive(:create_token).with("gph0hh0ahdbj6ng2cc3rvdecr8-token", expected_policy).and_return(["test-key", "test-secret"])
      expect(github_repository).to receive(:update).with(access_key: "test-key", secret_key: Digest::SHA256.hexdigest("test-secret"))
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end

    it "succeeds if the bucket already exists and access key does not exist" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur", github_cache_blob_storage_account_id: "123")
      expect(blob_storage_client).to receive(:create_bucket).and_raise(Aws::S3::Errors::BucketAlreadyOwnedByYou.new(nil, nil))
      expect(cloudflare_client).to receive(:create_token).and_return(["test-key", "test-secret"])
      expect(github_repository).to receive(:access_key).and_return(nil)
      expect(github_repository).to receive(:update).with(access_key: "test-key", secret_key: Digest::SHA256.hexdigest("test-secret"))
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end

    it "succeeds if the access and secret key already exist" do
      expect(github_repository).to receive(:access_key).and_return("test-key")
      expect(github_repository).to receive(:secret_key).and_return(Digest::SHA256.hexdigest("test-secret"))
      expect(github_repository).to receive(:lock!)
      github_repository.setup_blob_storage
    end
  end
end
