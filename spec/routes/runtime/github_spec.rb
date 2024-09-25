# frozen_string_literal: true

require_relative "spec_helper"

require "aws-sdk-s3"

RSpec.describe Clover, "github" do
  describe "authentication" do
    let(:vm) { create_vm }

    before { login_runtime(vm) }

    it "vm has no runner" do
      get "/runtime/github"

      expect(last_response).to have_api_error(400, "invalid JWT format or claim in Authorization header")
    end

    it "vm has runner but no repository" do
      GithubRunner.create_with_id(vm_id: vm.id, repository_name: "test", label: "ubicloud")
      get "/runtime/github"

      expect(last_response).to have_api_error(400, "invalid JWT format or claim in Authorization header")
    end

    it "vm has runner and repository" do
      repository = GithubRepository.create_with_id(name: "test", access_key: "key")
      GithubRunner.create_with_id(vm_id: vm.id, repository_name: "test", label: "ubicloud", repository_id: repository.id)
      get "/runtime/github"

      expect(last_response.status).to eq(404)
    end
  end

  it "setups blob storage if no access key" do
    vm = create_vm
    login_runtime(vm)
    repository = instance_double(GithubRepository, access_key: nil)
    expect(GithubRunner).to receive(:[]).with(vm_id: vm.id).and_return(instance_double(GithubRunner, repository: repository))
    expect(repository).to receive(:setup_blob_storage)

    post "/runtime/github/caches"

    expect(last_response).to have_api_error(400, "Wrong parameters")
  end

  describe "cache endpoints" do
    let(:repository) { GithubRepository.create_with_id(name: "test", default_branch: "main", access_key: "123") }
    let(:runner) { GithubRunner.create_with_id(vm_id: create_vm.id, repository_name: "test", label: "ubicloud", repository_id: repository.id, workflow_job: {head_branch: "dev"}) }
    let(:url_presigner) { instance_double(Aws::S3::Presigner, presigned_request: "aa") }
    let(:blob_storage_client) { instance_double(Aws::S3::Client) }

    before do
      login_runtime(runner.vm)
      allow(Aws::S3::Presigner).to receive(:new).and_return(url_presigner)
      allow(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
    end

    describe "reserves cache" do
      it "fails if one of the parameters are missing" do
        [
          [nil, "v1"],
          ["k1", nil]
        ].each do |key, version|
          params = {key: key, version: version}.compact
          post "/runtime/github/caches", params

          expect(last_response).to have_api_error(400, "Wrong parameters")
        end
      end

      it "fails if the runner doesn't have a scope" do
        runner.update(workflow_job: nil)
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 100}

        expect(last_response).to have_api_error(400, "No workflow job data available")
      end

      it "fails if cache is bigger than 10GB" do
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 11 * 1024 * 1024 * 1024}

        expect(last_response).to have_api_error(400, "The cache size is over the 10GB limit")
      end

      it "fails if the cache entry already exists" do
        GithubCacheEntry.create_with_id(key: "k1", version: "v1", scope: "dev", repository_id: repository.id, created_by: runner.id, committed_at: Time.now)
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 100}

        expect(last_response).to have_api_error(409, "A cache entry for dev scope already exists with k1 key and v1 version.")
      end

      it "Rollbacks inconsistent cache entry if a failure occurs in the middle" do
        expect(blob_storage_client).to receive(:create_multipart_upload).and_raise(CloverError.new(500, "UnexceptedError", "Sorry, we couldn’t process your request because of an unexpected error."))
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 75 * 1024 * 1024}

        expect(last_response).to have_api_error(500, "Sorry, we couldn’t process your request because of an unexpected error.")
        expect(repository.cache_entries).to be_empty
      end

      it "returns presigned urls and upload id for the reserved cache" do
        expect(blob_storage_client).to receive(:create_multipart_upload).and_return(instance_double(Aws::S3::Types::CreateMultipartUploadOutput, upload_id: "upload-id"))
        expect(url_presigner).to receive(:presigned_url).with(:upload_part, hash_including(bucket: repository.bucket_name, upload_id: "upload-id")) do |_, params|
          "url-#{params[:part_number]}"
        end.exactly(3).times
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 75 * 1024 * 1024}

        expect(last_response.status).to eq(200)
        response = JSON.parse(last_response.body)
        expect(response["uploadId"]).to eq("upload-id")
        expect(response["presignedUrls"]).to eq(["url-1", "url-2", "url-3"])

        entry = repository.cache_entries.first
        expect(entry.key).to eq("k1")
        expect(entry.version).to eq("v1")
        expect(entry.size).to eq(75 * 1024 * 1024)
        expect(entry.upload_id).to eq("upload-id")
      end

      it "returns presigned urls and upload id for the reserved cache without size" do
        expect(blob_storage_client).to receive(:create_multipart_upload).and_return(instance_double(Aws::S3::Types::CreateMultipartUploadOutput, upload_id: "upload-id"))
        expect(url_presigner).to receive(:presigned_url).with(:upload_part, hash_including(bucket: repository.bucket_name, upload_id: "upload-id")) do |_, params|
          "url-#{params[:part_number]}"
        end.exactly(320).times
        post "/runtime/github/caches", {key: "k1", version: "v1"}

        expect(last_response.status).to eq(200)
        response = JSON.parse(last_response.body)
        expect(response["uploadId"]).to eq("upload-id")
        expect(response["presignedUrls"].count).to eq(320)

        entry = repository.cache_entries.first
        expect(entry.key).to eq("k1")
        expect(entry.version).to eq("v1")
        expect(entry.size).to be_nil
        expect(entry.upload_id).to eq("upload-id")
      end
    end

    describe "commits cache" do
      it "fails if one of the parameters are missing" do
        [
          [["etag-1", "etag-2"], "upload-id", nil],
          [nil, "upload-id", 100],
          [["etag-1", "etag-2"], nil, 100]
        ].each do |etags, upload_id, size|
          params = {etags: etags, uploadId: upload_id, size: size}.compact
          post "/runtime/github/caches/commit", params

          expect(last_response).to have_api_error(400, "Wrong parameters")
        end
      end

      it "fails if there is no cache entry to commit" do
        post "/runtime/github/caches/commit", {etags: ["etag-1", "etag-2"], uploadId: "upload-id", size: 100}

        expect(last_response.status).to eq(204)
      end

      it "fails if there is no created multipart upload at blob storage" do
        GithubCacheEntry.create_with_id(key: "cache-key", version: "key-version", scope: "dev", repository_id: repository.id, created_by: runner.id, upload_id: "upload-id", size: 100)
        expect(blob_storage_client).to receive(:complete_multipart_upload).and_raise(Aws::S3::Errors::NoSuchUpload.new("error", "error"))
        post "/runtime/github/caches/commit", {etags: ["etag-1", "etag-2"], uploadId: "upload-id", size: 100}

        expect(last_response).to have_api_error(400, "Wrong parameters")
      end

      it "completes multipart upload" do
        entry = GithubCacheEntry.create_with_id(key: "cache-key", version: "key-version", scope: "dev", repository_id: repository.id, created_by: runner.id, upload_id: "upload-id", size: 100)
        expect(blob_storage_client).to receive(:complete_multipart_upload).with(
          hash_including(upload_id: "upload-id", multipart_upload: {parts: [{etag: "etag-1", part_number: 1}, {etag: "etag-2", part_number: 2}]})
        )
        post "/runtime/github/caches/commit", {etags: ["etag-1", "etag-2"], uploadId: "upload-id", size: 100}

        expect(last_response.status).to eq(200)
        expect(entry.reload.committed_at).not_to be_nil
      end

      it "completes multipart upload without size" do
        entry = GithubCacheEntry.create_with_id(key: "cache-key", version: "key-version", scope: "dev", repository_id: repository.id, created_by: runner.id, upload_id: "upload-id")
        expect(blob_storage_client).to receive(:complete_multipart_upload).with(
          hash_including(upload_id: "upload-id", multipart_upload: {parts: [{etag: "etag-1", part_number: 1}, {etag: "etag-2", part_number: 2}]})
        )
        post "/runtime/github/caches/commit", {etags: ["etag-1", "etag-2"], uploadId: "upload-id", size: 100}

        expect(entry.reload.size).to eq(100)
        expect(last_response.status).to eq(200)
        expect(entry.reload.committed_at).not_to be_nil
      end
    end

    describe "gets cache entry" do
      it "fails if one of the parameters are missing" do
        [
          ["k1,k2", nil],
          [nil, "v1"],
          ["", "v1"]
        ].each do |keys, version|
          params = {keys: keys, version: version}.compact
          get "/runtime/github/cache", params

          expect(last_response).to have_api_error(400, "Wrong parameters")
        end
      end

      it "fails if no cache entry found" do
        get "/runtime/github/cache", {keys: "k1", version: "v1"}

        expect(last_response.status).to eq(204)
      end

      it "returns a cache from default branch when no branch info" do
        runner.update(workflow_job: nil)
        entry = GithubCacheEntry.create_with_id(key: "k1", version: "v1", scope: "main", repository_id: repository.id, created_by: runner.id, committed_at: Time.now)
        expect(url_presigner).to receive(:presigned_url).with(:get_object, hash_including(bucket: repository.bucket_name, key: entry.blob_key)).and_return("http://presigned-url")
        get "/runtime/github/cache", {keys: "k1", version: "v1"}

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).slice("cacheKey", "cacheVersion", "scope").values).to eq(["k1", "v1", "main"])
      end

      it "returns the first matched cache with key for runner's branch" do
        [
          ["k1", "v1", "dev"],
          ["k1", "v2", "main"],
          ["k2", "v1", "main"],
          ["k2", "v1", "dev"]
        ].each do |key, version, branch|
          GithubCacheEntry.create_with_id(key: key, version: version, scope: branch, repository_id: repository.id, created_by: runner.id, committed_at: Time.now)
        end
        expect(url_presigner).to receive(:presigned_url).with(:get_object, anything).and_return("http://presigned-url")
        get "/runtime/github/cache", {keys: "k2", version: "v1"}

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).slice("cacheKey", "cacheVersion", "scope").values).to eq(["k2", "v1", "dev"])
        expect(GithubCacheEntry[key: "k2", version: "v1", scope: "dev"].last_accessed_by).to eq(runner.id)
      end

      it "partially matched key returns the most recently created cache" do
        GithubCacheEntry.create_with_id(key: "k1234", version: "v1", scope: "main", repository_id: repository.id, created_at: Time.now - 2, created_by: runner.id, committed_at: Time.now)
        GithubCacheEntry.create_with_id(key: "k12345", version: "v1", scope: "main", repository_id: repository.id, created_at: Time.now - 1, created_by: runner.id, committed_at: Time.now)
        GithubCacheEntry.create_with_id(key: "k123456", version: "v1", scope: "main", repository_id: repository.id, created_at: Time.now, created_by: runner.id, committed_at: Time.now)

        expect(url_presigner).to receive(:presigned_url).with(:get_object, anything).and_return("http://presigned-url")
        get "/runtime/github/cache", {keys: "k12,k123", version: "v1"}

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).slice("cacheKey", "cacheVersion", "scope").values).to eq(["k123456", "v1", "main"])
        expect(GithubCacheEntry[key: "k123456", version: "v1", scope: "main"].last_accessed_by).to eq(runner.id)
      end
    end

    describe "lists cache entries" do
      it "returns no content if the key is missing" do
        get "/runtime/github/caches", {key: nil}

        expect(last_response.status).to eq(204)
      end

      it "returns the list of cache entries for the key" do
        [
          ["k1", "v1", "dev"],
          ["k1", "v2", "main"],
          ["k1", "v1", "feature"],
          ["k2", "v1", "dev"]
        ].each do |key, version, branch|
          GithubCacheEntry.create_with_id(key: key, version: version, scope: branch, repository_id: repository.id, created_by: runner.id, committed_at: Time.now)
        end

        get "/runtime/github/caches", {key: "k1"}

        response = JSON.parse(last_response.body)
        expect(response["totalCount"]).to eq(2)
        expect(response["artifactCaches"].map { [_1["cacheKey"], _1["cacheVersion"]] }).to eq([["k1", "v1"], ["k1", "v2"]])
      end

      it "returns the list of cache entries for the default branch" do
        runner.update(workflow_job: nil)
        [
          ["k1", "v1", "dev"],
          ["k1", "v2", "main"],
          ["k1", "v1", "feature"],
          ["k2", "v1", "dev"]
        ].each do |key, version, branch|
          GithubCacheEntry.create_with_id(key: key, version: version, scope: branch, repository_id: repository.id, created_by: runner.id, committed_at: Time.now)
        end
        get "/runtime/github/caches", {key: "k1"}

        response = JSON.parse(last_response.body)
        expect(response["totalCount"]).to eq(1)
        expect(response["artifactCaches"].map { [_1["cacheKey"], _1["cacheVersion"]] }).to eq([["k1", "v2"]])
      end
    end
  end
end
