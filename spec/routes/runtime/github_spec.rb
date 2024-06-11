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
end
