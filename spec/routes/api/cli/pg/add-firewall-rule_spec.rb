# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-firewall-rule" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds a firewall rule to the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.firewall_rules_dataset.select_order_map(:cidr).map(&:to_s)).to eq %w[0.0.0.0/0]
    expect(cli(%w[pg eu-central-h1/test-pg add-firewall-rule 1.2.3.0/24])).to eq <<~END
      Firewall rule added to PostgreSQL database.
        rule id: #{pg.firewall_rules_dataset.first(cidr: "1.2.3.0/24").ubid}, cidr: 1.2.3.0/24
    END
    expect(pg.firewall_rules_dataset.select_order_map(:cidr).map(&:to_s)).to eq %w[0.0.0.0/0 1.2.3.0/24]
  end
end
