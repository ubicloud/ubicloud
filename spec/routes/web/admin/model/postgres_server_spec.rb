# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresServer" do
  include AdminModelSpecHelper

  before do
    project = Project.create(name: "test-project")
    resource = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    @instance = create_postgres_server(resource:)
    admin_account_setup_and_login
  end

  it "displays the PostgresServer instance page correctly" do
    click_link "PostgresServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServer - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServer #{@instance.ubid}"
  end

  it "can recycle a PostgresServer" do
    visit "/model/PostgresServer/#{@instance.ubid}"
    click_link "Recycle"
    click_button "Recycle"

    expect(page).to have_content("Recycle scheduled for PostgresServer")
    expect(Semaphore.where(strand_id: @instance.id, name: "recycle").count).to eq 1
  end
end
