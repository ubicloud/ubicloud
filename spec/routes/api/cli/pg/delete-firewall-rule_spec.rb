# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg delete-firewall-rule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "deletes the specified firewall rule for the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -P ps])
    pg = PostgresResource.first
    cli(%W[fw eu-central-h1/#{pg.ubid}-firewall create])
    cli(%W[fw eu-central-h1/#{pg.ubid}-firewall attach-subnet ps])
    expect(cli(%w[pg eu-central-h1/test-pg delete-firewall-rule a/b], status: 400)).to start_with "! Invalid firewall rule id format\n"
    cli(%w[pg eu-central-h1/test-pg add-firewall-rule 1.2.3.0/24])
    all = pg.pg_firewall_rules
    expect(all.length).to eq 2
    fwr = all.shift
    expect(cli(%W[pg eu-central-h1/test-pg delete-firewall-rule #{fwr.ubid}])).to eq "Firewall rule, if it exists, has been scheduled for deletion\n"
    expect(pg.pg_firewall_rules_dataset.select_map(:id)).to eq all.map(&:id)
  end
end
