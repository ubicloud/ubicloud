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
      target_vm_size: "standard-2",
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

  it "shows the app in the list and updates settings" do
    app = assemble_app
    visit "#{project.path}/app"
    expect(page).to have_content("my-app")

    visit "#{project.path}/app/#{app.ubid}"
    fill_in "GitHub repository URL", with: "https://github.com/new/repo"
    fill_in "Branch", with: "release"
    click_button "Save"

    expect(page).to have_flash_notice("App updated")
    app.reload
    expect(app.repo_url).to eq("https://github.com/new/repo")
    expect(app.branch).to eq("release")
  end

  it "deletes an app" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    click_button "Delete app"

    expect(page).to have_flash_notice("App 'my-app' is being deleted")
    expect(Semaphore.where(strand_id: app.id, name: "destroy").count).to eq(1)
  end

  it "deploys via the Deploy button" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    click_button "Deploy"

    expect(page).to have_flash_notice("Deploy of 'my-app' started")
    expect(app.deployments_dataset.count).to eq(1)
    expect(Semaphore.where(strand_id: app.id, name: "deploy").count).to eq(1)
  end

  it "scales a process via the form" do
    app = assemble_app
    visit "#{project.path}/app/#{app.ubid}"
    fill_in "Process", with: "web"
    fill_in "Replicas", with: "3"
    click_button "Scale"

    expect(page).to have_flash_notice("Scaled web to 3")
    expect(app.processes_dataset.first(process_type: "web").replica_count).to eq(3)
    expect(Semaphore.where(strand_id: app.id, name: "converge").count).to eq(1)
  end

  describe "with view-only access" do
    before do
      @app = assemble_app
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
      expect(page).to have_no_button("Scale")
    end
  end
end
