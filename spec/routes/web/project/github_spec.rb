# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }
  let(:installation) { GithubInstallation.create_with_id(installation_id: 123, name: "test-user", type: "User", project_id: project.id) }

  before do
    login(user.email)
  end

  it "disabled when GitHub app name not provided" do
    allow(Config).to receive(:github_app_name).and_return(nil)

    visit project.path
    within "#desktop-menu" do
      expect { click_link "GitHub Runners" }.to raise_error Capybara::ElementNotFound
    end
    expect(page.title).to eq("Ubicloud - #{project.name}")

    visit "#{project.path}/github"
    expect(page.status_code).to eq(501)
    expect(page).to have_content "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
  end

  context "when GitHub Integration enabled" do
    before do
      allow(Config).to receive(:github_app_name).and_return("runner-app")
    end

    it "raises forbidden when does not have permissions" do
      project_wo_permissions
      visit "#{project_wo_permissions.path}/github"

      expect(page.title).to eq("Ubicloud - Forbidden")
      expect(page.status_code).to eq(403)
      expect(page).to have_content "Forbidden"
    end

    it "can connect GitHub account" do
      visit "#{project.path}/github"

      click_link "Connect New Account"

      expect(page.status_code).to eq(200)
      expect(page.driver.request.session["login_redirect"]).to eq("/apps/runner-app/installations/new")
    end

    it "can not connect GitHub account if project has no valid payment method" do
      expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

      visit "#{project.path}/github"

      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "Project doesn't have valid billing information"

      click_link "Connect New Account"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "Project doesn't have valid billing information"
      expect(page.driver.request.session["login_redirect"]).not_to eq("/apps/runner-app/installations/new")
    end

    it "can list installations" do
      ins1 = GithubInstallation.create_with_id(installation_id: 111, name: "test-user", type: "User", project_id: project.id)
      ins2 = GithubInstallation.create_with_id(installation_id: 222, name: "test-org", type: "Organization", project_id: project.id)

      visit "#{project.path}/github"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "test-user"
      expect(page).to have_link "Configure", href: ins1.installation_url
      expect(page).to have_content "test-org"
      expect(page).to have_link "Configure", href: ins2.installation_url
    end

    it "can list active runners" do
      vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "runner-vm").subject
      runner2 = GithubRunner.create_with_id(
        installation_id: installation.id,
        label: "ubicloud",
        repository_name: "my-repo",
        runner_id: 2,
        workflow_job: {
          "id" => 123,
          "name" => "test-job",
          "run_id" => 456,
          "workflow_name" => "test-workflow"
        },
        vm_id: vm.id
      )
      Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo")

      visit "#{project.path}/github"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "Runner doesn't have a job yet"
      expect(page).to have_content runner2.ubid
      expect(page).to have_content "creating"
      expect(page).to have_content "not_created"
      expect(page).to have_link runner2.workflow_job["workflow_name"], href: runner2.run_url
      expect(page).to have_link runner2.workflow_job["name"], href: runner2.job_url
    end
  end
end
