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
      installation.update(allocator_preferences: {}, created_at: Time.utc(2026, 5, 1))

      # enable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be true
      expect(DB[:audit_log].where(action: "enable_premium").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_premium").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#premium_runner_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-premium", {premium_runner_enabled: false, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.premium_runner_enabled?).to be false
      expect(DB[:audit_log].where(action: "disable_premium").count).to eq(1)
    end

    it "shows badge for free premium runner upgrade" do
      now = Time.utc(2026, 6, 1)
      allow(Time).to receive(:now).and_return(now)
      project.set_ff_free_runner_upgrade_until(now + 100)

      visit "#{project.path}/github/#{installation.ubid}/setting"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You’re eligible for an exclusive 50% off premium runners"
    end

    it "toggles cache for installation" do
      installation.update(cache_enabled: false)

      # enable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_enabled).to be true
      expect(DB[:audit_log].where(action: "enable_cache").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache", {cache_enabled: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_cache").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_enabled_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
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
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
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
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache-scope", {cache_scope_protected: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(installation.reload.cache_scope_protected).to be true
      expect(DB[:audit_log].where(action: "enable_cache_scope").count).to eq(1)

      # no change
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_scope_protected_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
        page.driver.post "#{project.path}/github/#{installation.ubid}/set-cache-scope", {cache_scope_protected: true, _csrf:}
      end
      expect(page.status_code).to eq(302)
      expect(DB[:audit_log].where(action: "enable_cache_scope").count).to eq(1)

      # disable
      visit "#{project.path}/github/#{installation.ubid}/setting"
      within("form#cache_scope_protected_toggle") do
        _csrf = find_field(name: "_csrf", type: "hidden", visible: :hidden).value
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
        location_id: Location::GITHUB_RUNNERS_ID,
        workflow_job: {
          "id" => 123,
          "name" => "test-job",
          "run_id" => 456,
          "workflow_name" => "test-workflow",
          "created_at" => (now - 60).iso8601,
          "started_at" => (now - 40).iso8601,
        },
      )
      runner_waiting_job = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud", repository_name: "my-repo").subject.update(ready_at: now - 400, created_at: now)
      runner_not_created = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-arm", repository_name: "my-repo").subject.update(
        created_at: now - 38,
        vm_id: Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "runner-vm-2", size: "standard-4", arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID).id,
        location_id: Location::GITHUB_RUNNERS_ID,
      )
      runner_concurrency_limit = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-2", repository_name: "my-repo").update(label: "wait_concurrency_limit").subject.update(created_at: now - 3.68 * 60 * 60)
      runner_custom_label_quota = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-4", repository_name: "my-repo").update(label: "apply_custom_label_quota").subject.update(created_at: now - 120)
      runner_allocation_slot = Prog::Github::GithubRunnerNexus.assemble(installation, label: "ubicloud-standard-2", repository_name: "my-repo").update(label: "wait_allocation_slot").subject.update(created_at: now - 60)

      [
        [now, "standard-2", 15],
        [now - 3 * 24 * 60 * 60, "standard-16-arm", 200_000],
      ].each do |time, family, amount|
        BillingRecord.create(
          project_id: project.id,
          resource_id: project.id,
          resource_name: "Daily Usage #{time.strftime("%Y-%m-%d")}",
          span: Sequel::Postgres::PGRange.new(time, time),
          billing_rate_id: BillingRate.from_resource_properties("GitHubRunnerMinutes", family, "global", false, BILLING_RATE_ACTIVE_AT)["id"],
          amount:,
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
        ["my-repo", "#{runner_allocation_slot.ubid}\n2 vCPU\nstandard\nx64\nubuntu-24", "Queued for provisioning\nWaiting for 1m", "", ""],
        ["my-repo", "#{runner_custom_label_quota.ubid}\n4 vCPU\nstandard\nx64\nubuntu-24", "Checking concurrency quota for custom labels\nWaiting for 2m", "", ""],
        ["my-repo", "#{runner_concurrency_limit.ubid}\n2 vCPU\nstandard\nx64\nubuntu-24", "Reached your concurrency limit\nWaiting for 3h 40m 48s", "", ""],
      ]
      expect(page.all("#current-usages div").map { it.text.split("\n") }).to eq [
        ["Allocated vCPU", "4 vCPU"],
        ["Requested vCPU", "16 vCPU"],
        ["Today", "$0.02"],
        ["Last 30 Days", "$1600.02"],
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
      project.set_ff_free_runner_upgrade_until(Time.now + 100)

      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You’re eligible for an exclusive 50% off premium runners"

      find("a", text: /^You’re eligible/).click
      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - GitHub Runner Settings")
    end

    it "shows info about standard runners given premium hardware" do
      installation.update(allocator_preferences: {})

      vm = create_vm(project_id: project.id, name: "upgraded-vm", family: "premium", location_id: Location::GITHUB_RUNNERS_ID, allocated_at: Time.now)
      runner = GithubRunner.create(installation_id: installation.id, repository_name: repository.name, label: "ubicloud-standard-4", vm_id: vm.id, location_id: vm.location_id)
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")

      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "Some of your standard runners were given premium hardware instead, on us."
      expect(page).to have_no_content "Some of your premium runners were given standard hardware instead"

      runner.update(label: "ubicloud-premium-4")
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page).to have_no_content "Some of your standard runners were given premium hardware instead, on us."

      runner.update(label: "ubicloud-standard-4", vm_id: nil, location_id: nil)
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page).to have_content runner.ubid
      expect(page).to have_no_content "Some of your standard runners were given premium hardware instead, on us."
    end

    it "shows info about premium runners given standard hardware" do
      installation.update(allocator_preferences: {"family_filter" => ["premium", "standard"]})

      vm = create_vm(project_id: project.id, name: "downgraded-vm", family: "standard", location_id: Location::GITHUB_RUNNERS_ID, allocated_at: Time.now)
      runner = GithubRunner.create(installation_id: installation.id, repository_name: repository.name, label: "ubicloud-standard-4", vm_id: vm.id, location_id: vm.location_id)
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")

      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "Some of your premium runners were given standard hardware instead"
      expect(page).to have_no_content "Some of your standard runners were given premium hardware instead, on us."

      vm.update(allocated_at: nil)
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page).to have_no_content "Some of your premium runners were given standard hardware instead"

      vm.update(allocated_at: Time.now, arch: "arm64")
      runner.update(label: "ubicloud-standard-4-arm")
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page).to have_no_content "Some of your premium runners were given standard hardware instead"
    end

    it "shows concurrency warning for limited access accounts" do
      installation.project.update(reputation: "limited")
      3.times do |i|
        vm = create_vm(project_id: project.id, name: "test-vm-#{i}", vcpus: 60)
        runner = GithubRunner.create(installation_id: installation.id, repository_name: repository.name, label: "ubicloud-standard-60", vm_id: vm.id, location_id: vm.location_id)
        Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "wait")
      end
      visit "#{project.path}/github/#{installation.ubid}/runner"
      expect(page.status_code).to eq(200)
      expect(page).to have_content "You've reached your vCPU concurrency limit"
      expect(page).to have_content "we recommend updating your account email to your company email address"
      expect(page).to have_link "updating your account email", href: "/account/change-login"
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
      expect(page).to have_content "21.4 KB used of 100 GB"
      expect(page).to have_content "created just now"
      expect(page).to have_content "Never used"
      expect(page).to have_content "800 B"
      expect(page).to have_content "created 10 minutes ago"
      expect(page).to have_content "5 minutes ago"
      expect(page).to have_content "20.6 KB"
      expect(page).to have_content "created 4 days ago"
      expect(page).to have_content "3 hours ago"
    end

    it "shows the cache storage limit of each repository" do
      repository2 = GithubRepository.create(name: "test-user/test-repo2", installation_id: installation.id, extra_cache_storage_gib: 300)
      create_cache_entry(size: 800)
      create_cache_entry(size: 900, repository_id: repository2.id)

      visit "#{project.path}/github/#{installation.ubid}/cache"

      expect(page).to have_content "800 B used of 100 GB"
      expect(page).to have_content "900 B used of 400 GB"
    end

    it "can delete a cache entry" do
      entry = create_cache_entry(key: "new-cache")
      visit "#{project.path}/github/#{installation.ubid}/cache"
      find("#entry-#{entry.ubid} input[type=checkbox]").check
      click_button "Delete Selected Cache Entries"

      expect(DB[:audit_log].where(action: "destroy").count).to eq(1)
      expect(page.title).to eq "Ubicloud - Caches"
      expect(page).to have_flash_notice("1 cache entry scheduled for deletion")
      ds = Strand.where(prog: "Github::DeleteCacheEntries")
      expect(ds.count).to eq 1
      st = ds.first
      expect(st.stack[0]["subject_id"]).to eq entry.repository_id
      expect(st.stack[0]["cache_entry_ids"]).to eq [entry.id]
    end

    it "can delete multiple cache entries" do
      repository2 = GithubRepository.create(name: "test-user/test-repo2", installation_id: installation.id)
      entry1 = create_cache_entry(key: "cache-1")
      entry2 = create_cache_entry(key: "cache-2", repository_id: repository2.id)
      create_cache_entry(key: "cache-3")
      client = instance_double(Aws::S3::Client)
      allow(Aws::S3::Client).to receive(:new).and_return(client)
      allow(client).to receive(:delete_object)

      visit "#{project.path}/github/#{installation.ubid}/cache"
      find("#entry-#{entry1.ubid} input[type=checkbox]").check
      find("#entry-#{entry2.ubid} input[type=checkbox]").check
      click_button "Delete Selected Cache Entries"

      expect(page.title).to eq "Ubicloud - Caches"
      expect(page).to have_flash_notice("2 cache entries scheduled for deletion")
      expect(DB[:audit_log].where(action: "destroy").count).to eq(1)
      data = Strand.where(prog: "Github::DeleteCacheEntries")
        .map { it.stack[0].values_at("subject_id", "cache_entry_ids") }
        .sort
      expect(data).to eq({
        repository.id => [entry1.id],
        repository2.id => [entry2.id],
      }.sort)
    end

    it "handles no cache entries selected for deletion" do
      create_cache_entry(key: "new-cache")

      visit "#{project.path}/github/#{installation.ubid}/cache"
      click_button "Delete Selected Cache Entries"
      expect(page).to have_flash_notice("No cache entries selected for deletion")
      expect(page.title).to eq "Ubicloud - Caches"
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

  describe "runs" do
    let(:runs_path) { "#{project.path}/github/#{installation.ubid}/repository/#{repository.ubid}/runs" }

    def create_active_run(run_id, run_attempt: 1, **)
      GithubActiveWorkflowRun.create(
        installation_id: installation.id,
        repository_id: repository.id,
        repository_name: repository.name,
        create_date: Time.now.utc.to_date,
        run_id:,
        run_attempt:,
        event: "push",
        status: "queued",
        display_title: "Active #{run_id}-#{run_attempt}",
        actor_login: "octocat",
        cache_scope: "main",
        **,
      )
    end

    def create_completed_run(run_id, create_date: Time.now.utc.to_date, run_attempt: 1, **)
      GithubCompletedWorkflowRun.create_partition(create_date) unless GithubCompletedWorkflowRun.partition_days.include?(create_date)
      now = Time.now
      GithubCompletedWorkflowRun.insert(
        repository_id: repository.id,
        run_id:,
        run_attempt:,
        create_date:,
        installation_id: installation.id,
        created_at: now,
        run_started_at: now,
        completed_at: now,
        event: "push",
        status: "completed",
        conclusion: "success",
        display_title: "Completed #{run_id}-#{run_attempt}",
        actor_login: "octocat",
        duration: 90,
        **,
      )
    end

    def run_ids
      page.all("#workflow-runs tbody tr").map { it[:id] }
    end

    it "shows empty state with the searched date range if there are no matching runs" do
      today = Time.now.utc.to_date
      create_completed_run(300, create_date: today - 20)

      visit runs_path
      expect(page.status_code).to eq(200)
      expect(page.title).to eq "Ubicloud - Workflow Runs"
      expect(page).to have_content "No workflow runs were created between #{today - 6} and #{today} (UTC)."
      expect(page).to have_no_css ".auto-refresh"

      click_link "Older Runs"
      expect(page).to have_current_path("#{runs_path}?date=#{today - 7}")
      expect(page).to have_content "No workflow runs were created between #{today - 13} and #{today - 7} (UTC)."

      click_link "Older Runs"
      expect(page).to have_current_path("#{runs_path}?date=#{today - 14}")
      expect(run_ids).to eq %w[run-300-1]
      expect(page).to have_link "Older Runs", href: "?date=#{today - 21}"

      visit "#{runs_path}?date=#{today - 36}"
      expect(page).to have_content "No workflow runs were created between #{today - 42} and #{today - 36} (UTC)."
      expect(page).to have_no_content "Older Runs"

      visit "#{runs_path}?date=#{today - 100}"
      expect(page).to have_content "No workflow runs were created between #{today - 42} and #{today - 42} (UTC)."
      expect(page).to have_no_content "Older Runs"
    end

    it "shows details of active and completed workflow runs" do
      now = Time.now
      create_active_run(1006, created_at: now - 65)
      create_active_run(1005, run_attempt: 2, status: "in_progress", run_started_at: now - 125, head_branch: "feature", head_repository_full_name: "contributor/test-repo", commit_hash: "a" * 40, commit_message: "Active 1005-2\n\nDetails", event: "pull_request", actor_login: "alice")
      create_active_run(1004, status: "completed", conclusion: "success", run_started_at: now - 100, completed_at: now - 10, head_branch: "main", head_repository_full_name: repository.name)
      create_active_run(1003, status: "completed", conclusion: nil, completed_at: now - 10, commit_hash: "b" * 40, commit_message: "")
      create_completed_run(503, conclusion: "failure", head_branch: "main", commit_hash: "c" * 40, commit_message: "Fix bug\n\nLonger description")
      create_completed_run(502, conclusion: "action_required", run_started_at: nil, duration: nil)
      create_completed_run(501, conclusion: "cancelled", commit_hash: "d" * 40)

      visit runs_path

      expect(page.status_code).to eq(200)
      expect(page).to have_css ".auto-refresh"
      expect(run_ids).to eq %w[run-1006-1 run-1005-2 run-1004-1 run-1003-1 run-503-1 run-502-1 run-501-1]
      expect(page).to have_link "Older Runs", href: "?date=#{Time.now.utc.to_date - 7}"

      row = find_by_id("run-1006-1")
      expect(row).to have_content "Queued"
      expect(row).to have_content(/Queued for 1m \d+s/)
      expect(row).to have_content "Created 1 minutes ago"
      expect(row).to have_no_css "a.font-mono"

      row = find_by_id("run-1005-2")
      expect(row).to have_content "pull_request by alice"
      expect(row).to have_link "alice", href: "https://github.com/alice"
      expect(row).to have_content "In progress"
      expect(row).to have_content "contributor:feature"
      expect(row).to have_link "aaaaaaa", href: "https://github.com/contributor/test-repo/commit/#{"a" * 40}"
      expect(row).to have_no_content "Details"
      expect(row).to have_content(/Running for 2m \d+s/)
      expect(row).to have_content "Started 2 minutes ago"

      row = find_by_id("run-1004-1")
      expect(row).to have_content "Success"
      expect(row).to have_content "Took 1m 30s"
      expect(row).to have_no_content "contributor"

      row = find_by_id("run-1003-1")
      expect(row).to have_content "Completed"
      expect(row).to have_link "bbbbbbb", href: "https://github.com/#{repository.name}/commit/#{"b" * 40}"
      expect(row).to have_no_content "Took"
      expect(row).to have_content "Created just now"

      row = find_by_id("run-503-1")
      expect(row).to have_content "Failure"
      expect(row).to have_content "ccccccc Fix bug"
      expect(row).to have_no_content "Longer description"
      expect(row).to have_content "Took 1m 30s"

      row = find_by_id("run-502-1")
      expect(row).to have_content "Action required"
      expect(row).to have_no_content "Took"
      expect(row).to have_content "Created just now"

      row = find_by_id("run-501-1")
      expect(row).to have_content "Cancelled"
      expect(row).to have_link "ddddddd"
    end

    it "paginates through active and completed workflow runs" do
      today = Time.now.utc.to_date
      (1002..1026).each { create_active_run(it) }
      create_active_run(1001, run_attempt: 2)
      create_active_run(1001)
      (500..529).each { create_completed_run(it) }
      create_completed_run(400, create_date: today - 10)

      visit runs_path
      expect(run_ids).to eq((1002..1026).reverse_each.map { "run-#{it}-1" })

      click_link "Older Runs"
      expect(page).to have_current_path("#{runs_path}?run_id=1001&run_attempt=2")
      expect(run_ids).to eq(%w[run-1001-2 run-1001-1] + (507..529).reverse_each.map { "run-#{it}-1" })

      click_link "Older Runs"
      expect(page).to have_current_path("#{runs_path}?run_id=506&run_attempt=1&date=#{today}")
      expect(run_ids).to eq((500..506).reverse_each.map { "run-#{it}-1" })

      click_link "Older Runs"
      expect(page).to have_current_path("#{runs_path}?date=#{today - 7}")
      expect(run_ids).to eq %w[run-400-1]
      expect(page).to have_link "Older Runs", href: "?date=#{today - 14}"
      expect(page).to have_no_css ".auto-refresh"
    end

    describe "run" do
      let(:run_path_prefix) { "#{project.path}/github/#{installation.ubid}/repository/#{repository.ubid}/run" }

      def create_runner(job_id, **)
        GithubRunner.create(
          installation_id: installation.id,
          repository_id: repository.id,
          repository_name: repository.name,
          label: "ubicloud",
          run_id: 1005,
          run_attempt: 2,
          job_id:,
          job_name: "Runner job #{job_id}",
          **,
        )
      end

      def create_completed_job(job_id, create_date: Time.now.utc.to_date, **)
        GithubCompletedWorkflowJob.create_partition(create_date) unless GithubCompletedWorkflowJob.partition_days.include?(create_date)
        now = Time.now
        GithubCompletedWorkflowJob.insert(
          repository_id: repository.id,
          job_id:,
          workflow_run_create_date: create_date,
          installation_id: installation.id,
          runner_id: GithubRunner.generate_uuid,
          runner_vm_id: Vm.generate_uuid,
          completed_at: now,
          run_id: 1005,
          run_attempt: 2,
          workflow_name: "CI",
          job_name: "Completed job #{job_id}",
          job_created_at: now - 60,
          job_started_at: now - 50,
          job_completed_at: now - 5,
          ready_at: now - 55,
          status: "completed",
          conclusion: "failure",
          label: "ubicloud-standard-4",
          actual_label: "ubicloud-standard-4",
          billed_vm_size: "standard-4",
          vm_family: "standard",
          duration: 45,
          **,
        )
      end

      def job_ids
        page.all("#workflow-jobs tbody tr").map { it[:id] }
      end

      it "shows details of an active workflow run and its jobs" do
        now = Time.now
        today = Time.now.utc.to_date
        create_active_run(1005, run_attempt: 2, status: "in_progress", run_started_at: now - 125, head_branch: "feature", commit_hash: "a" * 40, commit_message: "Active 1005-2", event: "pull_request", actor_login: "alice")
        create_runner(30, workflow_name: "CI", status: "in_progress", job_created_at: now - 90, job_started_at: now - 80, label: "ubicloud-arm")
        create_runner(31, status: "completed", conclusion: "success", job_created_at: now - 90, job_started_at: now - 80, completed_at: now - 20)
        create_runner(32, status: "queued", job_created_at: now - 70)
        create_runner(33, status: "queued")
        create_completed_job(20)

        visit runs_path
        click_link "Active 1005-2"
        expect(page).to have_current_path("#{run_path_prefix}/#{today}/1005/2")

        expect(page.status_code).to eq(200)
        expect(page.title).to eq "Ubicloud - Workflow Run"
        expect(page).to have_css ".auto-refresh"
        expect(page).to have_content "In progress"
        expect(page).to have_content "CI"
        expect(page).to have_content "pull_request by alice"
        expect(page).to have_content "Attempt #2"
        expect(page).to have_content "feature"
        expect(page).to have_link "aaaaaaa", href: "https://github.com/#{repository.name}/commit/#{"a" * 40}"
        expect(page).to have_content(/Running for 2m \d+s/)
        expect(page).to have_link "View on GitHub", href: "https://github.com/#{repository.name}/actions/runs/1005/attempts/2"
        expect(job_ids).to eq %w[job-30 job-31 job-32 job-33 job-20]

        row = find_by_id("job-30")
        expect(row).to have_content "Runner job 30"
        expect(row).to have_content "In progress"
        expect(row).to have_content "ubicloud-arm"
        expect(row).to have_content(/Running for 1m \d+s/)
        expect(row).to have_content "Started 1 minutes ago"

        row = find_by_id("job-31")
        expect(row).to have_content "Success"
        expect(row).to have_content "Took 1m"
        expect(row).to have_content "Started 1 minutes ago"

        row = find_by_id("job-32")
        expect(row).to have_content "Queued"
        expect(row).to have_content(/Queued for 1m \d+s/)
        expect(row).to have_no_content "Started"

        row = find_by_id("job-33")
        expect(row).to have_content "Queued"
        expect(row).to have_no_content "Queued for"
        expect(row).to have_no_content "Started"

        row = find_by_id("job-20")
        expect(row).to have_content "Completed job 20"
        expect(row).to have_content "Failure"
        expect(row).to have_content "ubicloud-standard-4"
        expect(row).to have_content "Took 45s"
        expect(row).to have_content "Started just now"
      end

      it "shows details of a completed workflow run and its jobs" do
        today = Time.now.utc.to_date
        create_completed_run(1005, create_date: today - 2, run_attempt: 2)
        create_completed_job(20, create_date: today - 2, conclusion: "success")
        create_completed_job(21, create_date: today - 2)

        visit "#{runs_path}?date=#{today}"
        click_link "Completed 1005-2"
        expect(page).to have_current_path("#{run_path_prefix}/#{today - 2}/1005/2")

        expect(page.status_code).to eq(200)
        expect(page).to have_no_css ".auto-refresh"
        expect(page).to have_content "Took 1m 30s"
        expect(job_ids).to eq %w[job-20 job-21]
        expect(find_by_id("job-20")).to have_content "Success"
        expect(find_by_id("job-21")).to have_content "Failure"
      end

      it "shows empty state for a workflow run without jobs" do
        today = Time.now.utc.to_date
        create_completed_run(1005)

        visit "#{run_path_prefix}/#{today}/1005/1"
        expect(page.status_code).to eq(200)
        expect(page).to have_content "Completed 1005-1"
        expect(page).to have_no_content "Attempt #"
        expect(page).to have_content "No workflow jobs"
        expect(page).to have_no_css "#workflow-jobs thead"
      end

      it "returns 404 for missing workflow run or invalid date" do
        today = Time.now.utc.to_date
        create_completed_run(1005)

        visit "#{run_path_prefix}/#{today}/1005/2"
        expect(page.status_code).to eq(404)

        visit "#{run_path_prefix}/#{today - 1}/1005/1"
        expect(page.status_code).to eq(404)

        visit "#{run_path_prefix}/2026-02-30/1005/1"
        expect(page.status_code).to eq(404)
      end
    end
  end
end
