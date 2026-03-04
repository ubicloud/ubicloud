# frozen_string_literal: true

require "stripe"
require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id, created_at: Time.now - 10 * 24 * 60 * 60) }
  let(:repository) { GithubRepository.create(name: "test-user/test-repo", installation_id: installation.id) }

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
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

      visit "#{project.path}/github/create"

      expect(page.status_code).to eq(400)
      expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
      expect(page).to have_flash_error("Project doesn't have valid billing information")
    end

    it "shows new billing info button instead of connect account if project has no valid payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
      sessions_service = instance_double(Stripe::Checkout::SessionService)
      allow(StripeClient).to receive(:checkout).and_return(instance_double(Stripe::CheckoutService, sessions: sessions_service))

      # rubocop:disable RSpec/VerifiedDoubles
      expect(sessions_service).to receive(:create).and_return(double(Stripe::Checkout::Session, url: ""))
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

    it "toggles premium runners for installation" do
      installation.update(allocator_preferences: {})

      # enable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be true
      expect(DB[:audit_log].where(action: "enable_premium").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_premium").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: false, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be false
      expect(DB[:audit_log].where(action: "disable_premium").count).to eq(1)
    end

    it "shows badge for free premium runner upgrade" do
      installation.update(created_at: Time.now)

      visit "#{project.path}/github/#{installation.ubid}/setting"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You’re eligible for an exclusive 50% off premium runners"
    end

    it "toggles cache for installation" do
      installation.update(cache_enabled: false)

      # enable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_enabled).to be true
      expect(DB[:audit_log].where(action: "enable_cache").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_cache").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: false, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_enabled).to be false
      expect(DB[:audit_log].where(action: "disable_cache").count).to eq(1)
    end

    it "handles case where installation does not exist" do
      installation.update(cache_enabled: false)

      visit "#{project.path}/github/#{installation.ubid}/setting"

      within("form#cache_enabled_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        installation.destroy
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: true, _csrf:}
      end

      expect(page.status_code).to eq(404)
    end

    it "toggles cache scope protection for installation" do
      installation.update(cache_scope_protected: false)

      # enable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_scope_protected_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache-scope", {cache_scope_protected: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_scope_protected).to be true
      expect(DB[:audit_log].where(action: "enable_cache_scope").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_scope_protected_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache-scope", {cache_scope_protected: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_cache_scope").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_scope_protected_toggle") do
        _csrf = find("input[name='_csrf']", visible: false).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache-scope", {cache_scope_protected: false, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_scope_protected).to be false
      expect(DB[:audit_log].where(action: "disable_cache_scope").count).to eq(1)
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
      runner_deleted = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud", repository_name: "my-repo").update(label: "wait_vm_destroy")
      runner_with_job = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-4-ubuntu-2404", repository_name: "my-repo").subject.update(
        created_at: now + 20,
        ready_at: now - 50,
        runner_id: 2,
        vm_id: Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "runner-vm", size: "premium-4", location_id: Location::GITHUB_RUNNERS_ID).subject.update(allocated_at: now).id,
        workflow_job: {
          "id" => 123,
          "name" => "test-job",
          "run_id" => 456,
          "workflow_name" => "test-workflow",
          "created_at" => (now - 60).iso8601,
          "started_at" => (now - 40).iso8601
        }
      )
      runner_waiting_job = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject.update(ready_at: now - 400, created_at: now)
      runner_not_created = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-arm", repository_name: "my-repo").subject.update(
        created_at: now - 38,
        vm_id: Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "runner-vm-2", size: "standard-4", arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID).id
      )
      runner_concurrency_limit = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-2", repository_name: "my-repo").update(label: "wait_concurrency_limit").subject.update(created_at: now - 3.68 * 60 * 60)
      runner_custom_label_quota = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-4", repository_name: "my-repo").update(label: "apply_custom_label_quota").subject.update(created_at: now - 120)

      [
        [now, "standard-2", 15],
        [now - 3 * 24 * 60 * 60, "standard-16-arm", 200_000]
      ].each do |time, family, amount|
        BillingRecord.create(
          project_id: project.id,
          resource_id: project.id,
          resource_name: "Daily Usage #{time.strftime("%Y-%m-%d")}",
          span: Sequel::Postgres::PGRange.new(time, time),
          billing_rate_id: BillingRate.from_resource_properties("GitHubRunnerMinutes", family, "global")["id"],
          amount:
        )
      end

      visit "#{project.path}/github/#{installation.ubid}/runner"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Active Runners")
      expect(page).to have_no_content runner_deleted.ubid
      displayed_runner_rows = page.all("table.min-w-full tbody tr").map { |row| row.all("td").map(&:text) }
      expect(displayed_runner_rows).to eq [
        ["my-repo", "#{runner_with_job.ubid}\n4 vCPU\npremium\nx64\nubuntu-24", "test-workflow\ntest-job", "Running for 40s\nStarted in 20s", ""],
        ["my-repo", "#{runner_waiting_job.ubid}\n2 vCPU\nstandard\nx64\nubuntu-24", "Waiting for GitHub to assign a job\nReady for 6m 40s", "", ""],
        ["my-repo", "#{runner_not_created.ubid}\n2 vCPU\nstandard\narm64\nubuntu-24", "Provisioning an ephemeral virtual machine\nWaiting for 38s", "", ""],
        ["my-repo", "#{runner_custom_label_quota.ubid}\n4 vCPU\nstandard\nx64\nubuntu-24", "Checking concurrency quota for custom labels\nWaiting for 2m", "", ""],
        ["my-repo", "#{runner_concurrency_limit.ubid}\n2 vCPU\nstandard\nx64\nubuntu-24", "Reached your concurrency limit\nWaiting for 3h 40m 48s", "", ""]
      ]
      expect(page.all("#current-usages div").map { it.text.split("\n") }).to eq [
        ["Allocated vCPU", "4 vCPU"],
        ["Requested vCPU", "14 vCPU"],
        ["Today", "$0.01"],
        ["Last 30 Days", "$1280.01"]
      ]
    end

    it "can terminate runner" do
      runner = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject

      visit "#{project.path}/github/#{installation.ubid}/runner"

      expect(page.status_code).to eq(200)
      expect(page).to have_content runner.ubid

      find("#runner-#{runner.ubid} .delete-btn").click
      expect(page).to have_flash_notice("Runner '#{runner.ubid}' forcibly terminated")
    end

    it "raises not found when runner not exists" do
      runner = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject
      visit "#{project.path}/github/#{installation.ubid}/runner"
      runner_ubid = runner.ubid
      runner.destroy

      find("#runner-#{runner_ubid} .delete-btn").click
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

    it "shows concurrency warning for limited access accounts" do
      installation.project.update(reputation: "limited")
      Array.new(3).each {
        runner = GithubRunner.create(installation_id: installation.id, repository_name: repository.name, label: "ubicloud-standard-60")
        Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")
      }
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You've reached your vCPU concurrency limit"
    end
  end

  describe "custom-label" do
    before do
      project.set_ff_custom_runner_labels(true)
    end

    it "returns 404 when feature flag is not set" do
      project.set_ff_custom_runner_labels(nil)

      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      expect(page.status_code).to eq(404)
    end

    it "shows custom labels section on settings page" do
      GithubCustomLabel.create(installation_id: installation.id, name: "my-label", alias_for: "ubicloud-standard-4-ubuntu-2404")
      GithubCustomLabel.create(installation_id: installation.id, name: "big-runner", alias_for: "ubicloud-standard-16-ubuntu-2404", concurrent_runner_count_limit: 5)

      visit "#{project.path}/github/#{installation.ubid}/setting"

      expect(page.status_code).to eq(200)
      expect(page).to have_content "Custom Labels"
      expect(page).to have_content "big-runner"
      expect(page).to have_content "my-label"
      expect(page).to have_content "ubicloud-standard-4-ubuntu-2404"
      expect(page).to have_content "ubicloud-standard-16-ubuntu-2404"
      expect(page).to have_content "5"
      expect(page).to have_content "Unlimited"
    end

    it "does not show custom labels section when feature flag is not set" do
      project.set_ff_custom_runner_labels(nil)

      visit "#{project.path}/github/#{installation.ubid}/setting"

      expect(page.status_code).to eq(200)
      expect(page).to have_no_content "Custom Labels"
    end

    it "shows empty state when no custom labels" do
      visit "#{project.path}/github/#{installation.ubid}/setting"

      expect(page.status_code).to eq(200)
      expect(page).to have_content "No custom labels"
      expect(page).to have_content "Create custom runner labels to define friendly aliases or set concurrency limits for specific runner types."
      expect(page).to have_link "Add Custom Label"
    end

    it "renders create form" do
      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Add Custom Label")
      expect(page).to have_field "name"
      expect(page).to have_select "alias_for"
    end

    it "creates a custom label" do
      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      fill_in "name", with: "my-label"
      select "ubicloud-standard-4-ubuntu-2404", from: "alias_for"
      fill_in "concurrent_runner_count_limit", with: "3"
      click_button "Add Custom Label"

      expect(page).to have_flash_notice("Custom label 'my-label' created")
      expect(GithubCustomLabel.first(name: "my-label")).not_to be_nil
      expect(GithubCustomLabel.first(name: "my-label").concurrent_runner_count_limit).to eq(3)
    end

    it "creates a custom label without concurrency limit" do
      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      fill_in "name", with: "my-label"
      select "ubicloud-standard-4-ubuntu-2404", from: "alias_for"
      click_button "Add Custom Label"

      expect(page).to have_flash_notice("Custom label 'my-label' created")
      expect(GithubCustomLabel.first(name: "my-label").concurrent_runner_count_limit).to be_nil
    end

    it "fails to create with validation error" do
      GithubCustomLabel.create(installation_id: installation.id, name: "existing-label", alias_for: "ubicloud-standard-4-ubuntu-2404")

      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      fill_in "name", with: "existing-label"
      select "ubicloud-standard-4-ubuntu-2404", from: "alias_for"
      click_button "Add Custom Label"

      expect(page.status_code).to eq(400)
      expect(page.title).to eq("Ubicloud - Add Custom Label")
    end

    it "fails to create with name starting with ubicloud" do
      visit "#{project.path}/github/#{installation.ubid}/custom-label/create"

      fill_in "name", with: "ubicloud-my-label"
      select "ubicloud-standard-4-ubuntu-2404", from: "alias_for"
      click_button "Add Custom Label"

      expect(page.status_code).to eq(400)
      expect(page).to have_flash_error("name is reserved. Custom labels cannot start with 'ubicloud'")
      expect(page.title).to eq("Ubicloud - Add Custom Label")
    end

    it "renders edit form with existing values" do
      label = GithubCustomLabel.create(installation_id: installation.id, name: "my-label", alias_for: "ubicloud-standard-4-ubuntu-2404", concurrent_runner_count_limit: 5)

      visit "#{project.path}/github/#{installation.ubid}/custom-label/#{label.ubid}"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Edit Custom Label")
      expect(page).to have_field "name", with: "my-label"
      expect(page).to have_select "alias_for", selected: "ubicloud-standard-4-ubuntu-2404"
      expect(page).to have_field "concurrent_runner_count_limit", with: "5"
    end

    it "updates a custom label" do
      label = GithubCustomLabel.create(installation_id: installation.id, name: "my-label", alias_for: "ubicloud-standard-4-ubuntu-2404")

      visit "#{project.path}/github/#{installation.ubid}/custom-label/#{label.ubid}"

      fill_in "name", with: "updated-label"
      select "ubicloud-standard-16-ubuntu-2404", from: "alias_for"
      fill_in "concurrent_runner_count_limit", with: "10"
      click_button "Edit Custom Label"

      expect(page).to have_flash_notice("Custom label 'updated-label' updated")
      label.reload
      expect(label.name).to eq("updated-label")
      expect(label.alias_for).to eq("ubicloud-standard-16-ubuntu-2404")
      expect(label.concurrent_runner_count_limit).to eq(10)
    end

    it "deletes a custom label" do
      label = GithubCustomLabel.create(installation_id: installation.id, name: "my-label", alias_for: "ubicloud-standard-4-ubuntu-2404")

      visit "#{project.path}/github/#{installation.ubid}/setting"

      find("#label-#{label.ubid} .delete-btn").click
      expect(page).to have_flash_notice("Custom label 'my-label' deleted")
      expect(GithubCustomLabel[label.id]).to be_nil
    end

    it "returns 404 when custom label not found" do
      visit "#{project.path}/github/#{installation.ubid}/custom-label/#{GithubCustomLabel.generate_ubid}"

      expect(page.status_code).to eq(404)
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

      find("#entry-#{entry.ubid} .delete-btn").click
      expect(page).to have_flash_notice("Cache '#{entry.key}' deleted.")
    end

    it "raises not found when cache entry not exists" do
      entry = create_cache_entry(key: "new-cache")
      client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(client)
      expect(client).to receive(:delete_object).with(bucket: repository.bucket_name, key: entry.blob_key)

      visit "#{project.path}/github/#{installation.ubid}/cache"
      entry_ubid = entry.ubid
      entry.destroy

      find("#entry-#{entry_ubid} .delete-btn").click
      expect(page.status_code).to eq 404
    end

    it "can delete all cache entries for a repository" do
      entry = create_cache_entry(key: "cache-1")
      visit "#{project.path}/github/#{installation.ubid}/cache"

      expect(page.status_code).to eq(200)
      expect(page).to have_content "1 cache entries"

      find("#delete-all-#{repository.ubid}").click
      expect(page).to have_flash_notice("Scheduled deletion of existing cache entries")

      st = Strand.first(prog: "Github::DeleteCacheEntries")
      expect(st.label).to eq "delete_entries"
      st.destroy

      entry.this.delete(force: true)
      find("#delete-all-#{repository.ubid}").click
      expect(page).to have_flash_notice("No existing cache entries to delete")

      st = Strand.first(prog: "Github::DeleteCacheEntries")
      expect(st).to be_nil
    end
  end
end
