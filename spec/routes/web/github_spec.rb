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

  it "redirects to github page if already installed" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - Active Runners")
    expect(page).to have_flash_notice("GitHub runner integration is already enabled for #{project.name} project.")
  end

  it "raises forbidden when does not have permissions to access already enabled installation" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    project
    installation
    AccessControlEntry.dataset.update(action_id: ActionType::NAME_MAP["Project:view"])

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "fails if project not found at session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Projects")
    expect(page).to have_flash_error("You should initiate the GitHub App installation request from the project's GitHub runner integration page.")
  end

  it "raises forbidden when does not have permissions to the project in session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)
    AccessControlEntry.dataset.destroy

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "redirects to user management page if it requires approval" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)

    visit "/github/callback?code=123123&setup_action=request"

    expect(page.title).to eq("Ubicloud - #{project.name} - Users")
    expect(page).to have_flash_notice(/.*awaiting approval from the GitHub organization's administrator.*/)
  end

  it "fails if oauth code is invalid" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("invalid").and_return({})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)

    visit "/github/callback?code=invalid"

    expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
    expect(page).to have_flash_error(/^GitHub App installation failed.*/)
  end

  it "fails if installation not found" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: []})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)

    visit "/github/callback?code=123123"

    expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
    expect(page).to have_flash_error(/^GitHub App installation failed.*/)
  end

  it "fails if the project is not active" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)
    expect(project).to receive(:active?).and_return(false)

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - project-1 Dashboard")
    expect(page).to have_flash_error("GitHub runner integration is not allowed for inactive projects")
  end

  it "creates installation with project from session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})
    expect(Project).to receive(:[]).and_return(project).at_least(:once)

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Active Runners")
    expect(page).to have_flash_notice("GitHub runner integration is enabled for #{project.name} project.")
    installation = GithubInstallation[installation_id: 345]
    expect(installation.name).to eq("test-user")
    expect(installation.type).to eq("User")
    expect(installation.project_id).to eq(project.id)
  end
end
