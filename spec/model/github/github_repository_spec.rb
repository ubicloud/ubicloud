# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRepository do
  subject(:github_repository) {
    project = Project.create(name: "test")
    installation = GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
    described_class.create(name: "test-owner/test", installation:, access_key: "my-token-id")
  }

  let(:blob_storage_client) { instance_double(Aws::S3::Client) }
  let(:cloudflare_client) { instance_double(CloudflareClient) }

  before do
    allow(CloudflareClient).to receive(:new).and_return(cloudflare_client)
    allow(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
  end

  describe ".destroy_blob_storage" do
    let(:uploads) { instance_double(Aws::S3::Types::ListMultipartUploadsOutput, uploads: [instance_double(Aws::S3::Types::MultipartUpload, key: "test-key", upload_id: "test-upload-id")]) }

    it "deletes the bucket and token" do
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(uploads)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket: github_repository.bucket_name, key: "test-key", upload_id: "test-upload-id")
      expect(blob_storage_client).to receive(:delete_bucket).with(bucket: github_repository.bucket_name)
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key)
      github_repository.destroy_blob_storage
      expect(github_repository.reload.access_key).to be_nil
    end

    it "succeeds if the bucket is already deleted" do
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(instance_double(Aws::S3::Types::ListMultipartUploadsOutput, uploads: []))
      expect(blob_storage_client).to receive(:delete_bucket).and_raise(Aws::S3::Errors::NoSuchBucket.new(nil, nil))
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key)
      github_repository.destroy_blob_storage
      expect(github_repository.reload.access_key).to be_nil
    end

    it "succeed if can not abort multipart uploads" do
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(uploads)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket: github_repository.bucket_name, key: "test-key", upload_id: "test-upload-id").and_raise(Aws::S3::Errors::Unauthorized.new(nil, nil))
      expect(blob_storage_client).to receive(:delete_bucket).with(bucket: github_repository.bucket_name)
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key)
      github_repository.destroy_blob_storage
      expect(github_repository.reload.access_key).to be_nil
    end

    it "succeed if can not delete token" do
      expect(blob_storage_client).to receive(:list_multipart_uploads).and_return(uploads)
      expect(blob_storage_client).to receive(:abort_multipart_upload).with(bucket: github_repository.bucket_name, key: "test-key", upload_id: "test-upload-id")
      expect(blob_storage_client).to receive(:delete_bucket).with(bucket: github_repository.bucket_name)
      expect(cloudflare_client).to receive(:delete_token).with(github_repository.access_key).and_raise(Excon::Error::HTTPStatus.new("Expected(200) <=> Actual(520 Unknown)", nil, Excon::Response.new(body: "foo")))
      github_repository.destroy_blob_storage
      expect(github_repository.reload.access_key).to eq("my-token-id")
    end
  end

  describe ".setup_blob_storage" do
    before { github_repository.update(access_key: nil, secret_key: nil) }

    it "creates a bucket and token" do
      bucket_name = github_repository.bucket_name
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur", github_cache_blob_storage_account_id: "123")
      expect(blob_storage_client).to receive(:create_bucket).with({bucket: bucket_name, create_bucket_configuration: {location_constraint: "weur"}})
      expected_policy = [
        {
          "effect" => "allow",
          "permission_groups" => [{"id" => "2efd5506f9c8494dacb1fa10a3e7d5b6", "name" => "Workers R2 Storage Bucket Item Write"}],
          "resources" => {"com.cloudflare.edge.r2.bucket.123_default_#{bucket_name}" => "*"}
        }
      ]
      expect(cloudflare_client).to receive(:create_token).with("#{bucket_name}-token", expected_policy).and_return(["test-key", "test-secret"])
      expect(Clog).to receive(:emit).with("Blob storage setup completed", instance_of(Hash)).and_return({blob_storage_setup_completed: {bucket_name:}})
      github_repository.setup_blob_storage
      expect(github_repository.reload.access_key).to eq("test-key")
      expect(github_repository.secret_key).to eq(Digest::SHA256.hexdigest("test-secret"))
    end

    it "succeeds if the bucket already exists and access key does not exist" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur", github_cache_blob_storage_account_id: "123")
      expect(blob_storage_client).to receive(:create_bucket).and_raise(Aws::S3::Errors::BucketAlreadyOwnedByYou.new(nil, nil))
      expect(cloudflare_client).to receive(:create_token).and_return(["test-key", "test-secret"])
      github_repository.setup_blob_storage
      expect(github_repository.reload.access_key).to eq("test-key")
    end

    it "succeeds if the access and secret key already exist" do
      github_repository.update(access_key: "existing-key", secret_key: Digest::SHA256.hexdigest("existing-secret"))
      github_repository.setup_blob_storage
      expect(github_repository.reload.access_key).to eq("existing-key")
    end
  end
end
