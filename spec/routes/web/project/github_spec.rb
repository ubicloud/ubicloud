# frozen_string_literal: true

require "stripe"
require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }
  let(:installation) { GithubInstallation.create_with_id(installation_id: 123, name: "test-user", type: "User", project_id: project.id) }
  let(:repository) { GithubRepository.create_with_id(name: "test-repo", installation_id: installation.id) }

  before do
    login(user.email)
    allow(Config).to receive(:github_app_name).and_return("runner-app")
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

  it "raises forbidden when does not have permissions" do
    project_wo_permissions
    visit "#{project_wo_permissions.path}/github"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  describe "setting" do
    it "can connect GitHub account" do
      visit "#{project.path}/github"

      click_link "Connect New Account"

      expect(page.status_code).to eq(200)
      expect(page.driver.request.session["login_redirect"]).to eq("/apps/runner-app/installations/new")
    end

    it "can not connect GitHub account if project has no valid payment method" do
      expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

      visit "#{project.path}/github/installation/create"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "Project doesn't have valid billing information"
    end

    it "shows new billing info button instead of connect account if project has no valid payment method" do
      expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: ""))
      # rubocop:enable RSpec/VerifiedDoubles

      visit "#{project.path}/github"
      click_button "New Billing Information"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Project Billing")
    end

    it "can list installations" do
      ins1 = GithubInstallation.create_with_id(installation_id: 111, name: "test-user", type: "User", project_id: project.id)
      ins2 = GithubInstallation.create_with_id(installation_id: 222, name: "test-org", type: "Organization", project_id: project.id)

      visit "#{project.path}/github/setting"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content "test-user"
      expect(page).to have_link "Configure", href: /\/apps\/runner-app\/installations\/#{ins1.installation_id}/
      expect(page).to have_content "test-org"
      expect(page).to have_link "Configure", href: /\/apps\/runner-app\/installations\/#{ins2.installation_id}/
    end
  end

  describe "runner" do
    it "can list active runners" do
      runner_deleted = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").update(label: "wait_vm_destroy")
      runner_with_job = GithubRunner.create_with_id(
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
        vm_id: Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "runner-vm").id
      )
      runner_not_created = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo")
      runner_concurrency_limit = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").update(label: "wait_concurrency_limit")
      runner_wo_strand = GithubRunner.create_with_id(installation_id: installation.id, label: "ubicloud", repository_name: "my-repo")

      visit "#{project.path}/github/runner"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runners")
      expect(page).to have_content runner_deleted.ubid
      expect(page).to have_content "deleted"
      expect(page).to have_content "Runner doesn't have a job yet"
      expect(page).to have_content runner_with_job.ubid
      expect(page).to have_content "creating"
      expect(page).to have_link runner_with_job.workflow_job["workflow_name"], href: runner_with_job.run_url
      expect(page).to have_link runner_with_job.workflow_job["name"], href: runner_with_job.job_url
      expect(page).to have_content runner_not_created.ubid
      expect(page).to have_content "not_created"
      expect(page).to have_content runner_concurrency_limit.ubid
      expect(page).to have_content "reached_concurrency_limit"
      expect(page).to have_content runner_wo_strand.ubid
      expect(page).to have_content "not_created"
    end
  end

  describe "cache" do
    def create_cache_entry(**args)
      defaults = {key: "k#{Random.rand}", version: "v1", scope: "main", repository_id: repository.id, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b", committed_at: Time.now}
      GithubCacheEntry.create_with_id(**defaults.merge(args))
    end

    it "can list caches" do
      create_cache_entry(size: nil, created_at: Time.now, last_accessed_at: nil)
      create_cache_entry(size: 800, created_at: Time.now - 10 * 60, last_accessed_at: Time.now - 5 * 60)
      create_cache_entry(size: 20.6 * 1024, created_at: Time.now - 4 * 24 * 60 * 60, last_accessed_at: Time.now - 3 * 60 * 60)

      visit "#{project.path}/github/cache"

      expect(page.status_code).to eq(200)
      expect(page).to have_content "3 cache entries"
      expect(page).to have_content "21.4 KB used"
      expect(page).to have_content "created just now"
      expect(page).to have_content "Never used"
      expect(page).to have_content "800 B"
      expect(page).to have_content "created 10 minutes ago"
      expect(page).to have_content "5 minutes ago"
      expect(page).to have_content "20.6 KB"
      expect(page).to have_content "created 4 days ago"
      expect(page).to have_content "3 hours ago"
    end

    it "can delete cache entries" do
      entry = create_cache_entry(key: "new-cache")
      client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(client)
      expect(client).to receive(:delete_object).with(bucket: repository.bucket_name, key: entry.blob_key)

      visit "#{project.path}/github/cache"

      expect(page.status_code).to eq(200)
      expect(page).to have_content entry.key

      btn = find "#entry-#{entry.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(page.status_code).to eq(204)

      visit "#{project.path}/github/cache"
      expect(page).to have_content "Cache '#{entry.key}' deleted"
    end

    it "raises not found when cache entry not exists" do
      visit "#{project.path}/github/cache/etn0h8p5js1a4kpa9er7jkg77c"

      expect(page.title).to eq("Ubicloud - ResourceNotFound")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "ResourceNotFound"
    end
  end
end
