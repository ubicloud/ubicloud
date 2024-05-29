# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "github" do
  describe "authentication" do
    let(:vm) { create_vm }

    before { login_runtime(vm) }

    it "vm has no runner" do
      get "/runtime/github"

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
    end

    it "vm has runner but no repository" do
      GithubRunner.create_with_id(vm_id: vm.id, repository_name: "test", label: "ubicloud")
      get "/runtime/github"

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
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

    expect(last_response.status).to eq(400)
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
          ["k1", "v1", nil],
          [nil, "v1", 10],
          ["k1", nil, 10]
        ].each do |key, version, size|
          params = {key: key, version: version, cacheSize: size}.compact
          post "/runtime/github/caches", params

          expect(last_response.status).to eq(400)
          expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Wrong parameters")
        end
      end

      it "fails if the runner doesn't have a scope" do
        runner.update(workflow_job: nil)
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 100}

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("No workflow job data available")
      end

      it "fails if cache is bigger than 10GB" do
        post "/runtime/github/caches", {key: "k1", version: "v1", cacheSize: 11 * 1024 * 1024 * 1024}

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("The cache size is over the 10GB limit")
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
    end
  end
end
