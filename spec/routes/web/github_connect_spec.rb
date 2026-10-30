# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Clover, "github connect callback" do
  let(:project) { Project.create(name: "project-1") }
  let(:oauth_client) { instance_double(Octokit::Client) }
  let(:adhoc_client) { instance_double(Octokit::Client) }
  let(:installations) { {installations: [{id: 345, account: {login: "test-org"}}]} }

  def visit_callback(state: GithubConnectRequest.start(project.id).state, installation_id: 345, setup_action: "install")
    visit "/github/callback?code=123123&installation_id=#{installation_id}&setup_action=#{setup_action}&state=#{state}"
  end

  before do
    allow(Github).to receive(:oauth_client).and_return(oauth_client)
    allow(Octokit::Client).to receive(:new).with(access_token: "123").and_return(adhoc_client)
  end

  it "shows the code to enter in ubi gh connect without login" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return(installations)

    visit_callback

    expect(page.title).to eq("Ubicloud - Connect GitHub")
    expect(page).to have_content "Finish in your terminal"
    expect(page).to have_content "connect the GitHub account test-org to the Ubicloud project project-1"
    code = page.find(".copyable-content")["data-content"]
    expect(code).to match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/)
    expect(GithubConnectRequest.with_code(project.id, code).installation_id).to eq 345
    expect(GithubInstallation.count).to eq 0
  end

  it "uses the account name if the account has no login" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {name: "test-enterprise"}}]})

    visit_callback

    expect(page).to have_content "connect the GitHub account test-enterprise to the Ubicloud project project-1"
  end

  it "requires login for the callback without state" do
    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Login")
  end

  it "fails if the state is invalid" do
    visit_callback(state: "invalid")

    expect(page).to have_content "GitHub connection failed"
    expect(page).to have_content "The link is invalid or expired. Run ubi gh connect again."
  end

  it "fails if the state is already used" do
    request = GithubConnectRequest.start(project.id)
    request.set_code(345)
    visit_callback(state: request.state)

    expect(page).to have_content "The link is invalid or expired. Run ubi gh connect again."
  end

  it "fails if the state is expired" do
    state = GithubConnectRequest.start(project.id).state
    expect(Time).to receive(:now).and_return(Time.now + 10 * 60 + 1).at_least(:once)

    visit_callback(state:)

    expect(page).to have_content "The link is invalid or expired. Run ubi gh connect again."
  end

  it "fails if the installation needs approval from an administrator" do
    visit_callback(setup_action: "request")

    expect(page).to have_content "The installation is waiting for approval from an administrator of the GitHub organization."
  end

  it "fails if GitHub cannot be contacted" do
    expect(oauth_client).to receive(:exchange_code_for_token).and_raise(Faraday::ConnectionFailed.new("connection failed"))
    expect(Clog).to receive(:emit).with("GitHub connect callback failed", instance_of(Hash)).and_call_original

    visit_callback

    expect(page).to have_content "GitHub didn't confirm that you can manage the installation. Run ubi gh connect again."
  end

  it "fails if GitHub doesn't return an access token" do
    expect(oauth_client).to receive(:exchange_code_for_token).and_return({})

    visit_callback

    expect(page).to have_content "GitHub didn't confirm that you can manage the installation."
  end

  it "fails if the user cannot access the installation" do
    expect(oauth_client).to receive(:exchange_code_for_token).and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return(installations)

    visit_callback(installation_id: 999)

    expect(page).to have_content "GitHub didn't confirm that you can manage the installation."
  end

  it "fails if the access token is unauthorized" do
    expect(oauth_client).to receive(:exchange_code_for_token).and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_raise(Octokit::Unauthorized)

    visit_callback

    expect(page).to have_content "GitHub didn't confirm that you can manage the installation."
  end

  it "fails if the installation is already connected" do
    GithubInstallation.create(installation_id: 345, project_id: project.id, name: "test-org", type: "Organization")
    expect(oauth_client).to receive(:exchange_code_for_token).and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return(installations)

    visit_callback

    expect(page).to have_content "This GitHub installation is already connected to a Ubicloud project."
  end
end
