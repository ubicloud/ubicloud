# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg delete-firewall-rule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "deletes the specified firewall rule for the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    fwr = pg.firewall_rules_dataset.first
    expect(cli(%w[pg eu-central-h1/test-pg delete-firewall-rule a/b], status: 400)).to start_with "! Invalid firewall rule id format\n"
    expect(pg.firewall_rules_dataset).not_to be_empty
    expect(cli(%W[pg eu-central-h1/test-pg delete-firewall-rule #{fwr.ubid}])).to eq "Firewall rule, if it exists, has been scheduled for deletion\n"
    expect(pg.firewall_rules_dataset).to be_empty
  end
end
