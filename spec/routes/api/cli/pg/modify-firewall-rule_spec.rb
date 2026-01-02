# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg modify-firewall-rule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "modifies the cidr for the specified firewall rule for the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -P ps])
    pg = PostgresResource.first
    cli(%W[fw eu-central-h1/#{pg.ubid}-firewall create])
    cli(%W[fw eu-central-h1/#{pg.ubid}-firewall attach-subnet ps])
    cli(%W[fw eu-central-h1/#{pg.ubid}-firewall add-rule -s 5432 0.0.0.0/0])
    fwr = pg.customer_firewall.firewall_rules.first
    expect(cli(%w[pg eu-central-h1/test-pg modify-firewall-rule -c 1.2.3.0/24 a/b], status: 400)).to start_with "! Invalid firewall rule id format\n"
    expect(fwr.reload.cidr.to_s).to eq "0.0.0.0/0"
    expect(cli(%W[pg eu-central-h1/test-pg modify-firewall-rule -c 1.2.3.0/24 #{fwr.ubid}])).to eq "PostgreSQL database firewall rule modified.\n  rule id: #{fwr.ubid}\n  cidr: 1.2.3.0/24\n  description: \"\"\n"
    expect(fwr.reload.cidr.to_s).to eq "1.2.3.0/24"
    expect(cli(%W[pg eu-central-h1/test-pg modify-firewall-rule -c 1.2.3.0/24 -d] << "Example description" << fwr.ubid)).to eq "PostgreSQL database firewall rule modified.\n  rule id: #{fwr.ubid}\n  cidr: 1.2.3.0/24\n  description: \"Example description\"\n"
    expect(fwr.reload.cidr.to_s).to eq "1.2.3.0/24"
    expect(fwr.description).to eq "Example description"
  end
end
