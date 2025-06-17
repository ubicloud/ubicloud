# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg reset-superuser-password" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "schedules reset of superuser password for database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    expect(Semaphore.where(name: "update_superuser_password")).to be_empty
    pg = PostgresResource.first
    expect(cli(%w[pg eu-central-h1/test-pg reset-superuser-password fooBar123456])).to eq "Superuser password reset scheduled for PostgreSQL database with id: #{pg.ubid}\n"
    expect(Semaphore.where(name: "update_superuser_password")).not_to be_empty
    expect(pg.reload.superuser_password).to eq "fooBar123456"
  end
end
