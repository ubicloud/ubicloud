# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:installation) { GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User") }
  let(:oauth_client) { instance_double(Octokit::Client) }
  let(:adhoc_client) { instance_double(Octokit::Client) }

  before do
    login(user.email)

    allow(Config).to receive(:github_app_name).and_return("runner-app")
    allow(Github).to receive(:oauth_client).and_return(oauth_client)
    allow(Octokit::Client).to receive(:new).and_return(adhoc_client)
  end

  it "fails if oauth code is invalid" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("invalid").and_return({})

    visit "/github/callback?code=invalid"

    expect(page.title).to eq("Ubicloud - Dashboard")
    expect(page).to have_content("GitHub App installation failed.")
  end

  it "fails if installation not found" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: []})

    visit "/github/callback?code=123123"

    expect(page.title).to eq("Ubicloud - Dashboard")
    expect(page).to have_content("GitHub App installation failed.")
  end

  it "redirects to github page if already installed" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: installation.installation_id}]})

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - GitHub Runners")
    expect(page).to have_content("GitHub runner integration is already enabled for #{project.name} project.")
  end

  it "raises forbidden when does not have permissions to access already enabled installation" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: installation.installation_id}]})
    project.access_policies.first.update(body: {})

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "fails if project not found at session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345}]})

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Dashboard")
    expect(page).to have_content("Install GitHub App from project's 'GitHub Runners' page.")
  end

  it "fails if project has at least 1 account suspended" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)
    account = instance_double(Account, suspended_at: Time.now)
    expect(project).to receive(:accounts).and_return([account])

    visit "/github/callback?code=123123&installation_id=345"
    expect(page.title).to eq("Ubicloud - Dashboard")
    expect(page).to have_content("GitHub runner integration is not allowed for suspended accounts.")
  end

  it "raises forbidden when does not have permissions to create installation for project" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)
    project.access_policies.first.update(body: {})

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "creates installation with project from session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - GitHub Runners")
    expect(page).to have_content("GitHub runner integration is enabled for #{project.name} project.")
    installation = GithubInstallation[installation_id: 345]
    expect(installation.name).to eq("test-user")
    expect(installation.type).to eq("User")
    expect(installation.project_id).to eq(project.id)
  end
end
