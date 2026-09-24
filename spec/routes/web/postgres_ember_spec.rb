# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "postgres ember" do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  let(:ember) {
    c = create_postgres_ember(project_id: project.id, name: "my-ember")
    # Semaphores only insert where a strand with that id already exists.
    Strand.create_with_id(c, prog: "Ember::Nexus", label: "wait")
    c
  }

  before { login(user.email) }

  it "offers both types on the PostgreSQL page, and no page of its own" do
    visit "#{project.path}/postgres"
    expect(page.title).to eq "Ubicloud - PostgreSQL Databases"
    expect(page).to have_content "Ember"
    # Embers are part of the PostgreSQL product, not a section beside it.
    expect(page).to have_no_link "Embers", href: "#{project.path}/postgres-ember"
  end

  it "lists embers alongside dedicated databases" do
    ember
    visit "#{project.path}/postgres"
    expect(page).to have_content "my-ember"
    # Only the embers' table: an empty one for dedicated databases is left out.
    expect(page).to have_table(count: 1)
    click_link "my-ember"
    expect(page.title).to eq "Ubicloud - my-ember"
    expect(page).to have_content ember.ubid
  end

  it "creates one from the form behind the Ember card" do
    create_ember_template
    expect(PostgresEmberOperations).to receive(:create).and_return(ember)
    visit "#{project.path}/postgres/create"
    click_link "Ember"
    expect(page.title).to eq "Ubicloud - Create PostgreSQL Ember"
    fill_in "Name", with: "my-ember"
    click_button "Create"
    expect(page.title).to eq "Ubicloud - my-ember"
    expect(page).to have_flash_notice "Ember created"
  end

  it "pauses, resumes and resets the password" do
    visit "#{project.path}#{ember.path}"
    click_button "Pause"
    expect(page).to have_flash_notice "Ember will be paused"
    expect(ember.reload.semaphores.map(&:name)).to include("pause")

    ember.ember.update(state: "paused")
    page.refresh
    expect(EmberOperations).to receive(:resume)
    click_button "Resume"
    expect(page).to have_flash_notice "Ember resumed"

    old = ember.reload.superuser_password
    click_button "Reset Password"
    expect(page).to have_flash_notice "Superuser password reset"
    expect(ember.reload.superuser_password).not_to eq(old)
  end

  it "deletes one" do
    visit "#{project.path}#{ember.path}"
    click_button "Delete"
    expect(page).to have_flash_notice "Ember will be deleted"
    expect(ember.reload.semaphores.map(&:name)).to include("destroy")
  end

  it "hides the actions from somebody who may only look" do
    ember
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PostgresEmber:view"])
    visit "#{project.path}#{ember.path}"
    expect(page).to have_no_button "Pause"
    expect(page).to have_no_content "Reset the superuser password"
  end
end
