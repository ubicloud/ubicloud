# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id, created_at: Time.now - 10 * 24 * 60 * 60) }
  let(:repository) { GithubRepository.create(name: "test-user/test-repo", installation_id: installation.id) }
  let(:cache_entry) { GithubCacheEntry.create(key: "k#{Random.rand}", version: "v1", scope: "main", repository_id: repository.id, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b", committed_at: Time.now, size: 1) }

  before do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
    login_api
  end

  it "can get installation information" do
    get "/project/#{project.ubid}/github/#{installation.ubid}"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["name"]).to eq("test-user")
  end

  it "can get repository information" do
    get "/project/#{project.ubid}/github/test-user/repository/#{repository.ubid}"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["name"]).to eq("test-repo")
  end

  it "can get cache entry information" do
    get "/project/#{project.ubid}/github/test-user/repository/test-repo/cache/#{cache_entry.ubid}"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["key"]).to eq(cache_entry.key)
  end
end
