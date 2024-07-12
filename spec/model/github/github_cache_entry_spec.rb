# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubCacheEntry do
  subject(:entry) { described_class.create_with_id(repository_id: repository.id, key: "k1", version: "v1", scope: "main", upload_id: "upload-123", created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b") }

  let(:repository) { GithubRepository.create_with_id(name: "test") }

  describe ".after_destroy" do
    let(:client) { instance_double(Aws::S3::Client) }

    before { allow(Aws::S3::Client).to receive(:new).and_return(client) }

    it "deletes the object" do
      expect(entry).to receive(:committed_at).and_return(Time.now)
      expect(client).to receive(:delete_object).with(bucket: repository.bucket_name, key: entry.blob_key)
      entry.destroy
    end

    it "ignores if the object already deleted" do
      expect(entry).to receive(:committed_at).and_return(Time.now)
      expect(client).to receive(:delete_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, nil))
      entry.destroy
    end

    it "aborts the multipart upload if the cache not committed yet" do
      expect(entry).to receive(:committed_at).and_return(nil)
      expect(client).to receive(:abort_multipart_upload).with(bucket: repository.bucket_name, key: entry.blob_key, upload_id: entry.upload_id)
      expect(client).to receive(:delete_object)
      entry.destroy
    end

    it "ignores if the multipart upload already aborted" do
      expect(entry).to receive(:committed_at).and_return(nil)
      expect(client).to receive(:abort_multipart_upload).and_raise(Aws::S3::Errors::NoSuchUpload.new(nil, nil))
      expect(client).to receive(:delete_object)
      entry.destroy
    end
  end
end
