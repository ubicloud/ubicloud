# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresTimeline" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID)
    admin_account_setup_and_login
  end

  it "displays the PostgresTimeline instance page correctly" do
    click_link "PostgresTimeline"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresTimeline"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresTimeline #{@instance.ubid}"
  end

  it "displays the backups table" do
    mc = create_minio_cluster
    allow(Config).to receive(:postgres_service_project_id).and_return(mc.project_id)
    client = instance_double(Minio::Client, list_objects: [Struct.new(:key, :last_modified).new("basebackups_005/backup_stop_sentinel.json", Time.new(2020, 2, 29))])
    expect(Minio::Client).to receive(:new).and_return(client)

    visit "/model/PostgresTimeline/#{@instance.ubid}"
    expect(page.status_code).to eq 200
    expect(page).to have_table(class: "timeline-backups-table")
    expect(page).to have_content("2020-02-29")
  end

  it "displays no data available when there are no backups" do
    mc = create_minio_cluster
    allow(Config).to receive(:postgres_service_project_id).and_return(mc.project_id)
    client = instance_double(Minio::Client, list_objects: [])
    expect(Minio::Client).to receive(:new).and_return(client)

    visit "/model/PostgresTimeline/#{@instance.ubid}"
    expect(page.status_code).to eq 200
    expect(page).to have_content("No data available for Backups table")
  end
end
