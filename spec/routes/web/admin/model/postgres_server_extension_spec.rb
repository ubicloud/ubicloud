# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresServerExtension" do
  include AdminModelSpecHelper

  before do
    project = Project.create(name: "test-project")
    resource = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    server = create_postgres_server(resource:)
    @instance = PostgresServerExtension.create(
      postgres_server_id: server.id, name: "pgvector", state: "verifying",
      target_version: "0.7", installed_version: "0.7",
    )
    admin_account_setup_and_login
  end

  it "displays the PostgresServerExtension browse and instance pages" do
    click_link "PostgresServerExtension"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServerExtension - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServerExtension #{@instance.ubid}"
    expect(page.body).to include("pgvector")
    expect(page.body).to include("verifying")
  end

  it "searches by postgres_server ubid and by framework-handled columns" do
    click_link "PostgresServerExtension"
    click_link "Search"
    fill_in "postgres_server", with: @instance.postgres_server.ubid
    fill_in "name", with: "pgvector"
    click_button "Search"
    expect(page.status_code).to eq 200
    expect(page.body).to include(@instance.admin_label)
  end
end
