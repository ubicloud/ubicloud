# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg rename" do
  it "renames PostgreSQL database" do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.semaphores_dataset.all).to eq []
    expect(cli(%w[pg eu-central-h1/test-pg rename new-name])).to eq "PostgreSQL database renamed to new-name\n"
    expect(pg.reload.name).to eq "new-name"
    expect(pg.semaphores_dataset.select_order_map(:name)).to eq %w[refresh_certificates refresh_dns_record]
  end
end
