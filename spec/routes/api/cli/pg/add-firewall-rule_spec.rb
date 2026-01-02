# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-firewall-rule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -P ps])
    @pg = PostgresResource.first
    cli(%W[fw eu-central-h1/#{@pg.ubid}-firewall create])
    cli(%W[fw eu-central-h1/#{@pg.ubid}-firewall attach-subnet ps])
  end

  it "adds a firewall rule to the database" do
    expect(cli(%w[pg eu-central-h1/test-pg add-firewall-rule 1.2.3.0/24])).to eq <<~END
      Firewall rule added to PostgreSQL database.
        rule id: #{@pg.pg_firewall_rules.find { it.cidr.to_s == "1.2.3.0/24" && it.port_range.begin == 5432 }.ubid}
        cidr: 1.2.3.0/24
        description: ""
    END
    expect(@pg.pg_firewall_rules.map { [it.cidr.to_s, it.description] }.uniq).to eq [["1.2.3.0/24", nil]]
  end

  it "considers description when adding rule" do
    expect(cli(%w[pg eu-central-h1/test-pg add-firewall-rule -d] << "Example description" << "1.2.3.0/24")).to eq <<~END
      Firewall rule added to PostgreSQL database.
        rule id: #{@pg.pg_firewall_rules.find { it.cidr.to_s == "1.2.3.0/24" && it.port_range.begin == 5432 }.ubid}
        cidr: 1.2.3.0/24
        description: "Example description"
    END
    expect(@pg.pg_firewall_rules.map { [it.cidr.to_s, it.description] }.uniq).to eq [%w[1.2.3.0/24 Example\ description]]
  end
end
