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
    body = JSON.parse(last_response.body)
    expect(body["key"]).to eq(cache_entry.key)
    expect(body["scope"]).to eq("main")
    expect(body).to have_key("created_at")
    expect(body).to have_key("last_accessed_at")
  end

  it "returns last_accessed_at when cache entry was accessed" do
    cache_entry.update(last_accessed_at: Time.now)
    get "/project/#{project.ubid}/github/test-user/repository/test-repo/cache/#{cache_entry.ubid}"

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["last_accessed_at"]).not_to be_nil
    expect { Time.iso8601(body["last_accessed_at"]) }.not_to raise_error
  end

  describe "connect" do
    let(:app_client) { instance_double(Octokit::Client) }

    def connect_code(project, installation_id)
      GithubConnectRequest.start(project.id).set_code(installation_id)
    end

    it "returns the GitHub App installation URL with a state for the project" do
      post "/project/#{project.ubid}/github/connect"

      expect(last_response.status).to eq(200)
      url = JSON.parse(last_response.body)["url"]
      expect(url).to start_with("https://github.com/apps/test-app/installations/new?state=")
      expect(GithubConnectRequest.with_state(url.split("state=").last).project_id).to eq project.id
    end

    it "returns the URL even if project doesn't have valid billing information" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      post "/project/#{project.ubid}/github/connect"

      expect(last_response.status).to eq(200)
    end

    it "creates the installation with a valid code" do
      expect(Github).to receive(:app_client).and_return(app_client)
      expect(app_client).to receive(:installation).with(123).and_return({account: {login: "test-org", type: "Organization"}})
      post "/project/#{project.ubid}/github", {code: connect_code(project, 123)}.to_json

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include("name" => "test-org", "has_valid_payment_method" => true)
      installation = project.github_installations_dataset.first
      expect(installation.values).to include(installation_id: 123, name: "test-org", type: "Organization")
      expect(DB[:audit_log].where(action: "create", ubid_type: GithubInstallation.ubid_type).get(:object_ids).to_a).to eq [installation.id]
      expect(GithubConnectRequest.count).to eq 0
    end

    it "accepts the code in lowercase and without the dash" do
      expect(Github).to receive(:app_client).and_return(app_client)
      expect(app_client).to receive(:installation).with(123).and_return({account: {login: "test-org", type: "Organization"}})
      post "/project/#{project.ubid}/github", {code: connect_code(project, 123).downcase.delete("-")}.to_json

      expect(last_response.status).to eq(200)
    end

    it "fails to create the installation with an expired code" do
      code = connect_code(project, 123)
      expect(Time).to receive(:now).and_return(Time.now + 10 * 60 + 1).at_least(:once)
      post "/project/#{project.ubid}/github", {code:}.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: code")
    end

    it "creates the installation and reports a missing payment method" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect(Github).to receive(:app_client).and_return(app_client)
      expect(app_client).to receive(:installation).with(123).and_return({account: {login: "test-org", type: "Organization"}})
      post "/project/#{project.ubid}/github", {code: connect_code(project, 123)}.to_json

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["has_valid_payment_method"]).to be false
      expect(project.github_installations_dataset.count).to eq 1
    end

    it "uses the account name if the account has no login" do
      expect(Github).to receive(:app_client).and_return(app_client)
      expect(app_client).to receive(:installation).with(123).and_return({account: {name: "test-enterprise", type: "Enterprise"}})
      post "/project/#{project.ubid}/github", {code: connect_code(project, 123)}.to_json

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["name"]).to eq("test-enterprise")
    end

    it "fails to create the installation with a code for another project" do
      post "/project/#{project.ubid}/github", {code: connect_code(Project.create(name: "other"), 123)}.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: code")
      expect(GithubInstallation.count).to eq 0
    end

    it "fails to create the installation if the project has a suspended account" do
      project.add_account(Account.create(email: "suspend@example.com", suspended_at: Time.now))
      post "/project/#{project.ubid}/github", {code: connect_code(project, 123)}.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: project")
      expect(GithubInstallation.count).to eq 0
    end

    it "fails to create the installation if it is already connected" do
      post "/project/#{project.ubid}/github", {code: connect_code(project, installation.installation_id)}.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: code")
      expect(GithubInstallation.count).to eq 1
    end
  end
end
