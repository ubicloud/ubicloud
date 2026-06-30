# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg set-maintenance-window" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "sets or unsets maintenance window" do
    expect(@pg.maintenance_window_start_at).to be_nil
    expect(cli(%w[pg eu-central-h1/test-pg set-maintenance-window 22])).to eq "Starting hour for maintenance window for PostgreSQL database with id #{@pg.ubid} set to 22.\n"
    expect(@pg.reload.maintenance_window_start_at).to eq 22
    expect(cli(%w[pg eu-central-h1/test-pg set-maintenance-window] << "")).to eq "Unset maintenance window for PostgreSQL database with id #{@pg.ubid}.\n"
    expect(@pg.reload.maintenance_window_start_at).to be_nil
  end

  it "sets days" do
    @project.set_ff_postgres_enable_maintenance_window_days(true)
    expect(cli(%w[pg eu-central-h1/test-pg set-maintenance-window -d mon,wed 22])).to eq "Starting hour for maintenance window for PostgreSQL database with id #{@pg.ubid} set to 22.\n"
    @pg.reload
    expect(@pg.maintenance_window_start_at).to eq 22
    expect(@pg.maintenance_window_day_names).to eq(["mon", "wed"])
  end
end
