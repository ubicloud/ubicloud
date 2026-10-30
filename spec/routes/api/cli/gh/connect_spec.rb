# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli gh connect" do
  let(:app_client) { instance_double(Octokit::Client) }

  before do
    expect(Config).to receive(:github_app_name).and_return("test-app").at_least(:once)
  end

  def expect_installation
    expect(Github).to receive(:app_client).and_return(app_client)
    expect(app_client).to receive(:installation).with(123).and_return({account: {login: "test-org", type: "Organization"}})
  end

  it "shows the GitHub App installation URL and asks for the code" do
    body = cli(%w[gh connect], confirm_prompt: "Code")
    url = body[%r{https://github\.com\S+}]
    expect(url).to start_with("https://github.com/apps/test-app/installations/new?state=")
    expect(GithubConnectRequest.with_state(url.split("state=").last).project_id).to eq @project.id
    expect(body).to eq <<~END
      Open the following URL in your browser to install the Ubicloud GitHub App:

      #{url}

      After you install the app, GitHub redirects you to a Ubicloud page that shows a code.
      Enter the code below, or run: ubi gh connect --confirm=CODE
    END
  end

  it "connects the GitHub installation with the code" do
    expect_installation
    expect(cli(["gh", "connect", "--confirm=#{GithubConnectRequest.start(@project.id).set_code(123)}"])).to eq "Connected GitHub installation test-org to the project\n"
    expect(@project.github_installations_dataset.get(:installation_id)).to eq 123
  end

  it "connects the GitHub installation with the code entered at the prompt" do
    expect_installation
    expect(cli(["--confirm", GithubConnectRequest.start(@project.id).set_code(123), "gh", "connect"])).to eq "Connected GitHub installation test-org to the project\n"
    expect(@project.github_installations_dataset.get(:installation_id)).to eq 123
  end

  it "shows how to add a payment method if the project doesn't have one" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect_installation
    expect(cli(["gh", "connect", "--confirm=#{GithubConnectRequest.start(@project.id).set_code(123)}"])).to eq <<~END
      Connected GitHub installation test-org to the project

      The project doesn't have a valid payment method. GitHub Actions jobs don't start until you add one:

      #{Config.base_url}/project/#{@project.ubid}/billing
    END
  end

  it "fails with an invalid code" do
    expect(cli(%w[gh connect --confirm=invalid], status: 400)).to eq "! Unexpected response status: 400\nDetails: Validation failed for following fields: code\n  code: Code is invalid or expired\n"
    expect(GithubInstallation.count).to eq 0
  end
end
