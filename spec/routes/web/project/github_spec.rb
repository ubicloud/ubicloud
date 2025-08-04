# frozen_string_literal: true

require "stripe"
require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id, created_at: Time.now - 10 * 24 * 60 * 60) }
  let(:repository) { GithubRepository.create(name: "test-repo", installation_id: installation.id) }

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
    expect(page.body).to eq "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
  end

  it "raises forbidden when does not have permissions" do
    project_wo_permissions
    visit "#{project_wo_permissions.path}/github"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "redirects to the first installation if it exists" do
    installation

    visit "#{project.path}/github"

    expect(page.status_code).to eq(200)
    expect(page).to have_current_path("#{project.path}/github/#{installation.ubid}/runner")
    expect(page.title).to eq("Ubicloud - Active Runners")
  end

  describe "setting" do
    it "can connect GitHub account" do
      visit "#{project.path}/github"

      click_link "Connect New Account"

      expect(page.status_code).to eq(200)
      expect(page.driver.request.session["login_redirect"]).to eq("/apps/runner-app/installations/new")
    end

    it "can not connect GitHub account if project has no valid payment method" do
      expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

      visit "#{project.path}/github/create"

      expect(page.status_code).to eq(400)
      expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
      expect(page).to have_flash_error("Project doesn't have valid billing information")
    end

    it "shows new billing info button instead of connect account if project has no valid payment method" do
      expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project).thrice
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: ""))
      # rubocop:enable RSpec/VerifiedDoubles

      visit "#{project.path}/github"
      click_button "New Billing Information"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Project Billing")
    end

    it "can switch between installations" do
      ins1 = GithubInstallation.create(installation_id: 111, name: "test-user", type: "User", project_id: project.id)
      ins2 = GithubInstallation.create(installation_id: 222, name: "test-org", type: "Organization", project_id: project.id)

      visit "#{project.path}/github/#{ins1.ubid}/runner"

      click_link "test-org"

      expect(page.status_code).to eq(200)
      expect(page).to have_current_path("#{project.path}/github/#{ins2.ubid}/runner", ignore_query: true)
      expect(page.title).to eq("Ubicloud - Active Runners")

      click_link "test-user"

      expect(page.status_code).to eq(200)
      expect(page).to have_current_path("#{project.path}/github/#{ins1.ubid}/runner", ignore_query: true)
      expect(page.title).to eq("Ubicloud - Active Runners")
    end

    it "enables premium runners for installation" do
      installation.update(allocator_preferences: {})
      expect(installation.premium_runner_enabled?).to be false

      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}", {premium_runner_enabled: true, _csrf:}
      end

      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be true
    end

    it "disables premium runners for installation" do
      installation.update(allocator_preferences: {"family_filter" => ["standard", "premium"]})
      expect(installation.premium_runner_enabled?).to be true

      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}", {premium_runner_enabled: false, _csrf:}
      end

      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be false
    end

    it "shows badge for free premium runner upgrade" do
      installation.update(created_at: Time.now)

      visit "#{project.path}/github/#{installation.ubid}/setting"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You’re eligible for an exclusive 50% off premium runners"
    end

    it "enables cache for installation" do
      installation.update(cache_enabled: false)
      expect(installation.cache_enabled).to be false

      visit "#{project.path}/github/#{installation.ubid}/setting"

      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}", {cache_enabled: true, _csrf:}
      end

      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_enabled).to be true
    end

    it "handles case where installation does not exist" do
      installation.update(cache_enabled: false)

      visit "#{project.path}/github/#{installation.ubid}/setting"

      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        installation.destroy
        page.driver.post "#{project.path}/github/#{installation.ubid}", {cache_enabled: true, _csrf:}
      end

      expect(page.status_code).to eq(404)
    end

    it "disables cache for installation" do
      installation.update(cache_enabled: true)
      expect(installation.cache_enabled).to be true

      visit "#{project.path}/github/#{installation.ubid}/setting"

      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}", {cache_enabled: false, _csrf:}
      end

      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_enabled).to be false
    end

    it "raises not found when installation doesn't exist" do
      visit "#{project.path}/github/invalid_id"

      expect(page.status_code).to eq(404)
    end
  end

  describe "runner" do
    it "shows no active runner page" do
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "No active runners"
      expect(page).to have_no_content "You’re eligible for an exclusive 50% off premium runners"
    end

    it "can list active runners" do
      now = Time.now
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      runner_deleted = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").update(label: "wait_vm_destroy")
      runner_with_job = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud-standard-4-ubuntu-2404", repository_name: "my-repo").subject.update(
        created_at: now + 20,
        ready_at: now - 50,
        runner_id: 2,
        vm_id: Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "runner-vm", size: "premium-4", location_id: Location::GITHUB_RUNNERS_ID).id,
        workflow_job: {
          "id" => 123,
          "name" => "test-job",
          "run_id" => 456,
          "workflow_name" => "test-workflow",
          "created_at" => (now - 60).iso8601,
          "started_at" => (now - 40).iso8601
        }
      )
      runner_waiting_job = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject.update(ready_at: now - 400, created_at: now)
      runner_not_created = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud-arm", repository_name: "my-repo").subject.update(created_at: now - 38)
      runner_concurrency_limit = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud-gpu", repository_name: "my-repo").update(label: "wait_concurrency_limit").subject.update(created_at: now - 3.68 * 60 * 60)

      visit "#{project.path}/github/#{installation.ubid}/runner"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Active Runners")
      expect(page).to have_no_content runner_deleted.ubid
      displayed_runner_rows = page.all("table.min-w-full tbody tr").map { |row| row.all("td").map(&:text) }
      expect(displayed_runner_rows).to eq [
        ["my-repo", "#{runner_with_job.ubid}\n4 vCPU\npremium\nx64\nubuntu-24", "test-workflow\ntest-job", "Running for 40s\nStarted in 20s", ""],
        ["my-repo", "#{runner_waiting_job.ubid}\n2 vCPU\nstandard\nx64\nubuntu-22", "Waiting for GitHub to assign a job\nReady for 6m 40s", "", ""],
        ["my-repo", "#{runner_not_created.ubid}\n2 vCPU\nstandard\narm64\nubuntu-22", "Provisioning an ephemeral virtual machine\nWaiting for 38s", "", ""],
        ["my-repo", "#{runner_concurrency_limit.ubid}\n6 vCPU\nstandard-gpu\nx64\nubuntu-22", "Reached your concurrency limit\nWaiting for 3h 40m 48s", "", ""]
      ]
    end

    it "can terminate runner" do
      runner = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject

      visit "#{project.path}/github/#{installation.ubid}/runner"

      expect(page.status_code).to eq(200)
      expect(page).to have_content runner.ubid

      btn = find "#runner-#{runner.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(page.status_code).to eq(204)

      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page).to have_flash_notice("Runner '#{runner.ubid}' forcibly terminated")
    end

    it "raises not found when runner not exists" do
      runner = Prog::Vm::GithubRunner.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject
      visit "#{project.path}/github/#{installation.ubid}/runner"
      runner.destroy

      btn = find "#runner-#{runner.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.status_code).to eq(404)
    end

    it "shows badge for free premium runner upgrade" do
      installation.update(created_at: Time.now)

      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You’re eligible for an exclusive 50% off premium runners"

      find("a", text: /^You’re eligible/).click
      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runner Settings")
    end
  end

  describe "cache" do
    def create_cache_entry(**)
      GithubCacheEntry.create(key: "k#{Random.rand}", version: "v1", scope: "main", repository_id: repository.id, created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b", committed_at: Time.now, **)
    end

    it "can list caches" do
      create_cache_entry(size: nil, created_at: Time.now, last_accessed_at: nil)
      create_cache_entry(size: 800, created_at: Time.now - 10 * 60, last_accessed_at: Time.now - 5 * 60)
      create_cache_entry(size: 20.6 * 1024, created_at: Time.now - 4 * 24 * 60 * 60, last_accessed_at: Time.now - 3 * 60 * 60)

      visit "#{project.path}/github/#{installation.ubid}/cache"

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

      visit "#{project.path}/github/#{installation.ubid}/cache"

      expect(page.status_code).to eq(200)
      expect(page).to have_content entry.key

      btn = find "#entry-#{entry.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(page.status_code).to eq(204)

      visit "#{project.path}/github/#{installation.ubid}/cache"
      expect(page).to have_flash_notice("Cache '#{entry.key}' deleted.")
    end

    it "raises not found when cache entry not exists" do
      entry = create_cache_entry(key: "new-cache")
      client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(client)
      expect(client).to receive(:delete_object).with(bucket: repository.bucket_name, key: entry.blob_key)

      visit "#{project.path}/github/#{installation.ubid}/cache"
      entry.destroy

      btn = find "#entry-#{entry.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
      expect(page.status_code).to eq(404)
    end
  end
end
