# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "app" do
  let(:user) { create_account }
  let(:project) { user.projects.first }
  let(:app_project) { Project.create_with_id(Project.generate_uuid, name: "app-svc") }

  before do
    login(user.email)
    allow(Config).to receive_messages(app_service_project_id: app_project.id, control_plane_outbound_cidrs: ["172.16.0.0/16"])
  end

  def assemble_app(name: "my-app")
    Prog::AppService::AppResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name:,
      repo_url: "https://github.com/owner/repo",
      branch: "main",
    ).subject
  end

  it "navigates from the sidebar and shows an empty state" do
    visit project.path
    click_link "Apps", match: :first
    expect(page.title).to eq "Ubicloud - Apps"
    expect(page).to have_content("No Apps")
  end

  it "creates an app via the form and views it" do
    visit "#{project.path}/app"
    click_link "Create App"
    expect(page.title).to eq "Ubicloud - Create App"

    fill_in "Name", with: "my-app"
    fill_in "GitHub repository URL", with: "https://github.com/owner/repo"
    click_button "Create"

    expect(page).to have_flash_notice("App 'my-app' created")
    expect(page.title).to eq "Ubicloud - my-app"
    expect(page).to have_content("https://github.com/owner/repo")
    expect(page).to have_content("No deployments yet.")
    expect(AppResource.first(project_id: project.id, name: "my-app")).not_to be_nil
  end

  it "renders a rich overview with a release, processes, and database" do
    allow(Config).to receive(:postgres_service_project_id).and_return(app_project.id)
    app = assemble_app
    dep = AppDeployment.create(app_resource_id: app.id, version: 1, status: "active", commit_sha: "abc123def456")
    app.update(current_deployment_id: dep.id)
    app.attach_database

    visit "#{project.path}/app/#{app.ubid}"
    expect(page).to have_content("Release v1")
    expect(page).to have_content("abc123def456")
    expect(page).to have_content("PostgreSQL")
    expect(page).to have_content("1 instance")

    within "#app-submenu" do
      click_link "Deployments"
    end
    expect(page).to have_content("active")
    expect(page).to have_content("current")
  end

  it "shows the app in the list and updates settings" do
    app = assemble_app
    visit "#{project.path}/app"
    expect(page).to have_content("my-app")

    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Settings"
    end
    fill_in "GitHub repository URL", with: "https://github.com/new/repo"
    fill_in "Branch", with: "release"
    click_button "Save"

    expect(page).to have_flash_notice("App updated")
    app.reload
    expect(app.repo_url).to eq("https://github.com/new/repo")
    expect(app.branch).to eq("release")
  end

  it "deletes an app from the settings danger zone" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Settings"
    end
    click_button "Delete app"

    expect(page).to have_flash_notice("App 'my-app' is being deleted")
    expect(Semaphore.where(strand_id: app.id, name: "destroy").count).to eq(1)
  end

  it "deploys via the Deploy button on the overview" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    click_button "Deploy"

    expect(page).to have_flash_notice("Deploy of 'my-app' started")
    expect(app.deployments_dataset.count).to eq(1)
    expect(Semaphore.where(strand_id: app.id, name: "deploy").count).to eq(1)
  end

  it "scales a process inline from the processes table" do
    app = assemble_app # seeds a default "web" process
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Processes"
    end
    within "#process-web" do
      fill_in "replica_count-web", with: "3"
      select "standard-2", from: "vm_size-web"
      click_button "Save"
    end

    expect(page).to have_flash_notice("Scaled web to 3")
    process = app.processes_dataset.first(process_type: "web")
    expect(process.replica_count).to eq(3)
    expect(process.vm_size).to eq("standard-2")
    expect(Semaphore.where(strand_id: app.id, name: "converge").count).to eq(1)
  end

  it "shows an empty processes table before any process exists" do
    # A bare resource (no nexus) has no seeded web process.
    app = AppResource.create(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "bare-app", repo_url: "https://github.com/owner/repo", branch: "main")
    visit "#{project.path}/app/#{app.ubid}/processes"
    expect(page).to have_content("No processes yet")
    expect(page).to have_no_button("Save")
  end

  it "shows the logs page" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Logs"
    end
    expect(page.title).to end_with("Logs")
    expect(page).to have_content("No logs in the last 30 minutes")
  end

  it "manages config inline via the config page" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Config"
    end
    expect(page.title).to end_with("Config")

    within "#config-new" do
      fill_in "config-key-new", with: "API_KEY"
      fill_in "config-value-new", with: "s3cr3t"
      click_button "Add"
    end
    expect(page).to have_flash_notice("Config 'API_KEY' saved")
    expect(app.secret_store.secrets_dataset.first(key: "API_KEY").value).to eq("s3cr3t")

    # The value field is pre-filled and editable in place.
    within "#config-API_KEY" do
      expect(page).to have_field("config-value-API_KEY", with: "s3cr3t")
      fill_in "config-value-API_KEY", with: "updated"
      click_button "Save"
    end
    expect(page).to have_flash_notice("Config 'API_KEY' saved")
    expect(app.secret_store.secrets_dataset.first(key: "API_KEY").value).to eq("updated")

    within "#config-API_KEY" do
      click_button "Delete"
    end
    expect(page).to have_flash_notice("Config 'API_KEY' deleted")
    expect(app.secret_store.secrets_dataset.first(key: "API_KEY")).to be_nil
  end

  it "renames a config key by editing it in place" do
    app = assemble_app
    app.secret_store.add_secret(key: "OLD_KEY", value: "v")

    visit "#{project.path}/app/#{app.ubid}/config"
    within "#config-OLD_KEY" do
      fill_in "config-key-OLD_KEY", with: "NEW_KEY"
      fill_in "config-value-OLD_KEY", with: "v2"
      click_button "Save"
    end

    expect(page).to have_flash_notice("Config 'NEW_KEY' saved")
    expect(app.secret_store.secrets_dataset.first(key: "OLD_KEY")).to be_nil
    expect(app.secret_store.secrets_dataset.first(key: "NEW_KEY").value).to eq("v2")
  end

  it "tolerates a stale original_key when the row was already removed elsewhere" do
    app = assemble_app
    secret = app.secret_store.add_secret(key: "OLD_KEY", value: "v")

    visit "#{project.path}/app/#{app.ubid}/config"
    # The row was rendered, but the underlying secret is gone by submit time.
    secret.destroy
    within "#config-OLD_KEY" do
      fill_in "config-key-OLD_KEY", with: "NEW_KEY"
      fill_in "config-value-OLD_KEY", with: "v2"
      click_button "Save"
    end

    expect(page).to have_flash_notice("Config 'NEW_KEY' saved")
    expect(app.secret_store.secrets_dataset.first(key: "NEW_KEY").value).to eq("v2")
  end

  it "redeploys the app when config changes after it has shipped" do
    app = assemble_app
    AppDeployment.create(app_resource_id: app.id, version: 1, status: "active")

    visit "#{project.path}/app/#{app.ubid}/config"
    within "#config-new" do
      fill_in "config-key-new", with: "API_KEY"
      fill_in "config-value-new", with: "s3cr3t"
      click_button "Add"
    end
    expect(page).to have_flash_notice("Config 'API_KEY' saved; redeploying to apply it")
    expect(app.deployments_dataset.count).to eq(2)
    expect(Semaphore.where(strand_id: app.id, name: "deploy").count).to eq(1)

    within "#config-API_KEY" do
      click_button "Delete"
    end
    expect(page).to have_flash_notice("Config 'API_KEY' deleted; redeploying to apply it")
    expect(app.deployments_dataset.count).to eq(3)
  end

  it "creates and detaches a database via the database page" do
    allow(Config).to receive(:postgres_service_project_id).and_return(app_project.id)
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Database"
    end
    expect(page.title).to end_with("Database")
    expect(page).to have_content("No database attached")

    click_button "Create database"
    expect(page).to have_flash_notice("Database is being provisioned")
    expect(app.reload.postgres_resource).not_to be_nil
    expect(page).to have_content("Managed PostgreSQL")

    click_button "Detach database"
    expect(page).to have_flash_notice("Database detached")
    expect(app.reload.postgres_resource_id).to be_nil
  end

  it "shows the metrics empty state when no database is attached" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    within "#app-submenu" do
      click_link "Metrics"
    end
    expect(page.title).to end_with("Metrics")
    expect(page).to have_content("No metrics yet")
    expect(page).to have_no_css("#metrics-container")
  end

  it "shows the database metric charts when a database is attached" do
    allow(Config).to receive(:postgres_service_project_id).and_return(app_project.id)
    app = assemble_app
    app.attach_database

    visit "#{project.path}/app/#{app.ubid}/metrics"
    expect(page.title).to end_with("Metrics")
    expect(page).to have_css("#metrics-container")
    expect(page).to have_css("#cpu_usage-chart")
  end

  describe "with view-only access" do
    before do
      @app = assemble_app # seeds a default "web" process
      @app.secret_store.add_secret(key: "API_KEY", value: "s3cr3t")
      AccessControlEntry.dataset.destroy
      AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["AppResource:view"])
    end

    it "can view but cannot see edit or delete controls or the create button" do
      visit "#{project.path}/app"
      expect(page).to have_no_content("Create App")

      visit "#{project.path}/app/#{@app.ubid}"
      expect(page.status_code).to eq 200
      expect(page).to have_content("https://github.com/owner/repo")
      expect(page).to have_no_button("Save")
      expect(page).to have_no_button("Delete app")
      expect(page).to have_no_button("Deploy")
    end

    it "renders read-only processes and config without editable fields" do
      visit "#{project.path}/app/#{@app.ubid}/processes"
      within "#process-web" do
        expect(page).to have_content("web")
        expect(page).to have_content("hobby-1")
        expect(page).to have_no_button("Save")
        expect(page).to have_no_select("vm_size-web")
      end

      visit "#{project.path}/app/#{@app.ubid}/config"
      within "#config-API_KEY" do
        expect(page).to have_content("API_KEY")
        expect(page).to have_no_button("Save")
        expect(page).to have_no_button("Delete")
      end
      expect(page).to have_no_css("#config-new")
    end
  end
end
