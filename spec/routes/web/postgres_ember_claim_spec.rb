# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "ember claim" do
  let(:user) { create_account }

  let(:project) { user.projects.first }

  let(:service_project) { Project.create(name: "ember-service") }

  let(:token) { "token-that-was-handed-out" }

  let(:ember) {
    pg_ember = create_postgres_ember(project_id: service_project.id, name: "unclaimed-ember",
      claim_token_digest: PostgresEmber.hash_claim_token(token))
    Strand.create_with_id(pg_ember, prog: "Ember::Nexus", label: "wait")
    pg_ember
  }

  before do
    allow(Config).to receive(:ember_service_project_id).and_return(service_project.id)
    login(user.email)
  end

  it "claims the ember into a project the account picked" do
    project
    ember
    visit "/postgres-ember/claim?token=#{token}"
    expect(page.title).to eq "Ubicloud - Claim a Postgres Ember"
    select project.name, from: "project"
    click_button "Claim"
    expect(page).to have_flash_notice "Ember claimed."
    expect(page.title).to eq "Ubicloud - unclaimed-ember"
    expect(ember.reload.project_id).to eq(project.id)
    expect(ember.claim_token_digest).to be_nil
  end

  it "says so when there is no project to claim into" do
    Project.where(id: project.id).update(visible: false)
    visit "/postgres-ember/claim?token=#{token}"
    expect(page).to have_content "No project to claim into"
  end

  it "shows the form again, with the reason, when the token matches nothing" do
    project
    visit "/postgres-ember/claim?token=nope"
    select project.name, from: "project"
    click_button "Claim"
    expect(page.title).to eq "Ubicloud - Claim a Postgres Ember"
    expect(page).to have_flash_error "No unclaimed ember for that token"
  end

  it "refuses a project the account cannot create embers in" do
    project
    AccessControlEntry.dataset.destroy
    visit "/postgres-ember/claim?token=#{token}"
    select project.name, from: "project"
    click_button "Claim"
    expect(page.status_code).to eq(403)
  end
end
