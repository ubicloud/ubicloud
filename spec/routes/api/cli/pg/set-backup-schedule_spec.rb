# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg set-backup-schedule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "sets the backup schedule" do
    expect(cli(%w[pg eu-central-h1/test-pg set-backup-schedule -p 12 -s 3 -r 14])).to eq "Backup schedule for PostgreSQL database with id #{@pg.ubid} updated: every 12 hours, window opens at 3:00 UTC, point-in-time recovery for 14 days.\n"
    timeline = @pg.timeline.reload
    expect(timeline.backup_period_hours).to eq 12
    expect(timeline.backup_window_start_at).to eq 3
    expect(timeline.backup_retention_days).to eq 14
  end

  it "leaves omitted values unchanged and unsets the start hour" do
    cli(%w[pg eu-central-h1/test-pg set-backup-schedule -s 3 -r 14])
    expect(cli(%w[pg eu-central-h1/test-pg set-backup-schedule -s] << "")).to eq "Backup schedule for PostgreSQL database with id #{@pg.ubid} updated: every 24 hours, any start time, point-in-time recovery for 14 days.\n"
    timeline = @pg.timeline.reload
    expect(timeline.backup_window_start_at).to be_nil
    expect(timeline.backup_retention_days).to eq 14
  end

  it "leaves the start hour unchanged when it is omitted" do
    cli(%w[pg eu-central-h1/test-pg set-backup-schedule -s 3])
    expect(cli(%w[pg eu-central-h1/test-pg set-backup-schedule -p 6])).to eq "Backup schedule for PostgreSQL database with id #{@pg.ubid} updated: every 6 hours, window opens at 3:00 UTC, point-in-time recovery for 7 days.\n"
    expect(@pg.timeline.reload.backup_window_start_at).to eq 3
  end
end
